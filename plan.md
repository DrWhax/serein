Plan: "SignalSafe" — a native Swift/SwiftUI Signal Desktop for macOS

 Context

 Signal Desktop (upstream clone at Signal-Desktop/, v8.36.0-alpha.1, Electron 45 + React 19 + TypeScript,
 ~116k lines of UI code) parses every attachment, sticker, avatar and link-preview image through Chromium.
 The goal is a macOS-only rewrite where every parser of untrusted media is memory-safe Swift — no ImageIO,
 no VideoToolbox/AudioToolbox, no CoreMedia demuxing — while the UI is a pixel-for-pixel SwiftUI copy of
 upstream and the feature set matches upstream minus backups. Signal's Rust libraries (libsignal 0.106.0,
 ringrtc 2.73.0) are reused for the protocol, networking and calling, as upstream already does.

 Decisions taken with the user (2026-11-04):
 - Parser scope: everything in Swift — still images, animated images, audio (MP3/AAC), video (H.264), containers (MP4/ISOBMFF).
 - HEIC (HEVC intra) and AVIF (AV1 intra) are implemented in Swift (last phase, since they are the heaviest).
 - macOS 27 only, Xcode 27 / Swift 6.4, arm64 only to start.
 - Linked device only (QR provisioning), no history import on link, no standalone registration, no backups.

 Assumptions stated here, not asked (change them if wrong):
 - Calling keeps ringrtc + its bundled WebRTC (C++: libvpx, libjpeg-turbo, Opus…). Those codecs only touch SFU/peer media, not attachments. The user explicitly allowed repurposing the Rust calling libraries.
 - SQLCipher (C) via GRDB is acceptable for the local DB, as in Signal-iOS. TLS/HTTP via URLSession, WebSocket via libsignal-net (Rust).
 - Fonts (Inter, Signal Symbols icon font, story fonts) are trusted bundled assets rendered by CoreText. Emoji render with Apple Color Emoji via CoreText (upstream's "Signal Emoji" font is Apple-derived, so this stays visually 1:1). Bundled sounds/*.ogg are converted to PCM at build time so no Vorbis decoder is needed.
 - Bundled SVG icons are converted at build time into Swift Shape code so ImageIO is never used even for trusted assets.

 Upstream facts the plan builds on (from exploration)

 Area: Chat socket, REST-over-socket, provisioning socket
 Upstream location: ts/textsecure/SocketManager.preload.ts, WebsocketResources.preload.ts,
   Provisioner.preload.ts
 Backed by Rust today?: libsignal-net (Net, AuthenticatedChatConnection, connectProvisioning)
 ────────────────────────────────────────
 Area: Sessions, sealed sender, sender keys, PQ prekeys
 Upstream location: ts/SignalProtocolStore.preload.ts (2.9k), ts/LibSignalStores.node.ts
 Backed by Rust today?: libsignal-client; store persistence is app code
 ────────────────────────────────────────
 Area: Groups v2
 Upstream location: ts/groups.preload.ts (7.8k), ts/util/zkgroup.node.ts, protos/Groups.proto
 Backed by Rust today?: zkgroup only; HTTPS to storage host is app code
 ────────────────────────────────────────
 Area: Storage service
 Upstream location: ts/services/storage.preload.ts (3.2k), storageRecordOps.preload.ts (3.6k),
   protos/SignalStorage.proto
 Backed by Rust today?: none (AES-GCM + record merge in app)
 ────────────────────────────────────────
 Area: Attachments
 Upstream location: ts/AttachmentCrypto.node.ts, ts/util/uploads/tusProtocol.node.ts,
   ts/jobs/AttachmentDownloadManager.preload.ts
 Backed by Rust today?: incremental MAC only
 ────────────────────────────────────────
 Area: Message pipeline
 Upstream location: ts/textsecure/MessageReceiver.preload.ts (4.6k), SendMessage.preload.ts (3k),
   ts/background.preload.ts (4.2k), protos/SignalService.proto
 Backed by Rust today?: —
 ────────────────────────────────────────
 Area: DB
 Upstream location: ts/sql/Server.node.ts (9.9k), DATABASE_SCHEMA.md (~55 tables, latest migration 1870)
 Backed by Rust today?: sqlcipher
 ────────────────────────────────────────
 Area: Calling
 Upstream location: ts/services/calling.preload.ts (4.8k), ts/calling/VideoSupport.preload.ts
 Backed by Rust today?: ringrtc (Node binding; Swift wrapper exists for iOS only)
 ────────────────────────────────────────
 Area: UI
 Upstream location: 479 components in ts/components, 70 Axo primitives in ts/axo, tokens in
   ts/axo/AxoTokens.std.ts + ts/axo/_tailwind-theme/*.css, 289 Storybook stories
 Backed by Rust today?: —
 ────────────────────────────────────────
 Area: i18n
 Upstream location: _locales/*/messages.json, 68 locales, 3,109 ICU keys
 Backed by Rust today?: —
 ────────────────────────────────────────
 Area: Mock server
 Upstream location: packages/mock-server (chat, CDN, CDSI, storage, groups, mock SFU)
 Backed by Rust today?: used by ts/test-mock

 Image/audio/video formats upstream actually handles (allowlist ts/util/GoogleChrome.std.ts,ts/types/MIME.std.ts):
 JPEG (baseline+progressive, EXIF orientation), PNG/APNG (stickers), GIF animated, WebP (VP8/VP8L/VP8Xanim — stickers, jumbomoji), BMP, ICO, XBM, AVIF, HEIC (send-side), SVG never for attachments.
 Encoders needed: JPEG (scaled sends at 1600/2048/4096 px, q 0.7–0.75; avatars 512 px), PNG (150 pxthumbnails, poster frames), WebP q0.8 (sticker creator), blurhash 4×3.
 Audio: voice notes sent as MP3 (LAME VBR q7 ~90 kbps), received as MP3 or AAC-LC (from mobile). Video:MP4/H.264 (+AAC); Giphy "GIFs" are MP4 H.264 with the GIF flag.

 Repository layout (new, next to the upstream clone)

 signal-safe/
   Signal-Desktop/            upstream reference (read-only, pinned 5dad34ad)
   vendor/libsignal           git submodule, tag v0.106.0
   vendor/ringrtc             git submodule, tag v2.73.0
   SignalSafe.xcworkspace
   App/SignalSafe/            macOS app target (SwiftUI App lifecycle, AppDelegate formenu/dock/notifications)
   Packages/
     SignalCodecs/            SwiftPM, zero dependencies, all untrusted-media parsers
       CodecCore              bit/byte readers, Huffman, IDCT, YUV↔RGB, SIMD helpers, PixelBuffer, bounded allocators
       ImageJPEG  ImagePNG(+APNG)  ImageGIF  ImageWebP  ImageBMP(+ICO,XBM)  ImageHEIF(+HEVC intra)ImageAVIF(+AV1 intra)
       Blurhash  EncodeJPEG  EncodePNG  EncodeWebP
       ContainerMP4 (ISOBMFF demux + faststart-aware)  VideoH264  AudioAAC  AudioMP3(+encoder)
       Fuzz/                  libFuzzer targets per decoder (Swift `-sanitize=fuzzer`)
     SignalCore/              protocol + data layer (depends on LibSignalClient, GRDB+SQLCipher, SwiftProtobuf)
       Protos (generated from Signal-Desktop/protos/*.proto)  Database  ProtocolStores  Provisioning  Account
       Net (WebAPI endpoints, CDN, TUS, link-preview proxy)  Messaging (receive/send/sync)  Groups  StorageService
       Attachments  Stickers  Profiles  Usernames  KeyTransparency  Jobs  RemoteConfig  Notifications
     SignalRingRTC/           ringrtc Rust FFI built for aarch64-apple-darwin + Swift wrapper ported fromvendor/ringrtc/src/ios
     SignalUI/                SwiftUI design system + every screen (mirrors ts/components + ts/axoone-to-one)
     SignalI18n/              ICU MessageFormat runtime + generated string tables from _locales
   Tools/                     build-time generators (tokens, icons→Shape, locales, protos, sound→PCM, font convert)
   Tests/Integration/         Swift tests driving packages/mock-server

 Swift 6 language mode, strict concurrency, -warnings-as-errors. SignalCodecs forbids Unsafe* outside CodecCore/Unsafe/ (enforced by a lint script) and runs under ASan/UBSan in CI.

 Parsing discipline: LangSec, grammar-driven parsers (applies to every untrusted-input parser)

 Principles (Sassaman/Patterson/Bratus "language-theoretic security"): untrusted input is recognised by an explicit grammar before any semantic action; no shotgun parsing (no interleaving of partial parsing with decoding/allocation); grammars are kept in the weakest class that fits (regular or deterministiccontext-free with bounded lookahead), length fields are checked against the remaining input in the grammar; the recogniser produces a fully typed AST and only the AST reaches the decoder; parser code isthe single place raw bytes are touched.

 Implementation:
 1. CodecCore/Grammar — a Hammer-style parser-combinator library in Swift (result-builder DSL): byte andbit-level primitives (u8, u16be/le, u24, u32, bits(n), expGolomb, signedExpGolomb), sequence, choice (ordered, PEG-style, no unbounded backtracking), repeat(count:), repeat(until:), lengthPrefixed(by:)(the length field bounds the sub-parser's input slice — the sub-parser can never read past it), tagged(fourcc:), conditional(on:) for spec syntax tables ("if (flag) …"), validate { } for semanticpredicates on already-parsed fields, attempt/bounded limits on recursion depth and total node count. Every combinator is total over its input: it returns a typed value or a structuredParseFailure(offset, rule, reason), never traps. No Unsafe* in the library.
 2. One Grammar.swift per format that transcribes the spec's syntax tables literally (ITU/ISO specs arealready written as bitstream syntax tables, which map one-to-one onto the DSL): PNG chunk stream + each chunk body (IHDR/PLTE/tRNS/acTL/fcTL/fdAT/IDAT/IEND, CRC checked in the grammar), JPEG markersegments (SOF0/1/2, DHT, DQT, DRI, SOS, APPn incl. the EXIF TIFF IFD grammar, RSTn), GIF blocks (header, LSD, GCT, image descriptor, extensions, sub-block chains), RIFF/WebP(VP8X/VP8/VP8L/ALPH/ANIM/ANMF/ICCP/EXIF, VP8 frame header + partition sizes, VP8L header + transforms), BMP/ICO/XBM, ISOBMFF box tree (shared by MP4 and HEIF; iloc/iinf/ipco item grammars),H.264 NAL/SPS/PPS/slice-header grammar (Annex B and avcC), HEVC VPS/SPS/PPS/slice-segment-header, AV1 OBU/sequence header/frame header, AAC ADTS header + AudioSpecificConfig, MP3 frame header + Xing/LAMEtag, Blurhash string grammar. Also non-media untrusted inputs: Deflate/zlib stream grammar (block headers, Huffman tables), OpenGraph/<meta>/<link> subset of HTML for link previews, Giphy/Tenor JSONvia Codable with strict schemas, sticker manifest and jumbomoji packs via SwiftProtobuf (its generated parser is the recogniser).
 3. Two-stage decoders: Grammar → AST (value types) → Decoder. The entropy-coded payloads (Huffman scan data, VP8/VP8L bool-coded data, CABAC/CAVLC slice data, AAC spectral data) are not context-free, sothe grammar captures their framing and all parameters (table definitions, sizes, counts, partition boundaries), validates every invariant the spec states (e.g. Huffman code lengths form a valid prefixcode, partition sizes sum to the chunk, SPS dimensions within limits, num_ref_frames bounds), and the decoder stage then consumes the bounded slices through a checked BitReader whose every read isrange-checked and whose exhaustion is a typed error. Decoders allocate only after the AST is complete and validated (dimensions × bpp ≤ cap), so no allocation is driven by partially parsed input.
 4. Grammar as test oracle: each grammar doubles as a generator (Grammar.generate(using: RandomSource)) to produce structurally valid inputs for property-based tests and as fuzz seed corpora; fuzzers thenmutate from valid structures, which reaches deep paths faster than byte fuzzing. Negative tests assert that every validate predicate has a failing case and that parse failures carry the right offset/rule.
 5. Reviewability: grammars are kept side-by-side with the spec table numbers in comments, so an auditor can diff grammar against spec. A CI rule forbids Data/[UInt8] subscripting outside CodecCore/Grammarand CodecCore/BitReader; decoders receive only AST types and bounded reader handles.
 6. The same library is used in SignalCore for the few hand-parsed network formats: TUS/CDN responseheaders, the provisioning URL, group-link and username-link URL payloads, the attachment-pointer digest/padding checks, and the ProvisionEnvelope framing before protobuf decode.

 Phase 0 — Foundations (vendoring, Rust builds, generators)

 1. Add submodules; build vendor/libsignal with swift/build_ffi.sh --release for host(aarch64-apple-darwin), vendor its swift/ package as LibSignalClient (it already builds/tests on macOS). Verify Net, ChatConnection, zkgroup, usernames, IncrementalMac, Mp4Sanitizer/WebpSanitizersymbols exist in the Swift API (vendor/libsignal/swift/Sources/LibSignalClient).
 2. ringrtc spike (finding 2026-11-04): ringrtc's iOS C FFI is compiled only for `target_os = "ios"` and its Swift wrapper depends on the iOS Objective-C WebRTC SDK, so it is **not** the macOS path. Instead build ringrtc's platform-neutral `native` API (the one Signal Desktop's Electron binding wraps; cubeb audio, RGBA video sinks) with `cargo build -p ringrtc --release --lib --features native,prebuilt_webrtc --target aarch64-apple-darwin`, and add our own crate `Packages/SignalRingRTC/rust` exposing a C ABI over `native` that mirrors `src/rust/src/electron.rs` (3.5k lines, Neon) without Node.
 3. Generators in Tools/ (Swift scripts, run as SwiftPM plugins):
    - protos: protoc --swift_out for SignalService, Groups, SignalStorage, DeviceMessages, DeviceName,Stickers, JumboPack, KeyTransparency, CallQualitySurvey, Migrations, LibSignal-Client (skip Backups, LocalBackup).
    - tokens: parse ts/axo/AxoTokens.std.ts, ts/axo/_tailwind-theme/colors.css|fonts.css|shadows.css|…, stylesheets/_variables.scss → SignalUI/Tokens.generated.swift (colors with light/dark pairs, typescale, avatar palette A100–A210, chat colours from ts/types/ChatStyle.std.ts, z-index, sizes like header 52 px, nav rail 80 px).
    - icons: SVG path → SwiftUI Shape for the ~330 SVGs in images/; the 666 Signal Symbols glyphs stay as the variable font (fonts/SignalSymbolsVariable.woff2), decoded from WOFF2 at build time to TTF witha small Swift WOFF2→TTF tool (Brotli + glyf/loca untransform) and mapped via ts/axo/_internal/AxoSymbolDefs.generated.std.ts.
    - locales: _locales/*/messages.json → Swift string tables + a Swift ICU MessageFormat runtime (plural/select/argument, same subset upstream uses via @formatjs/intl).
    - sounds: decode sounds/*.ogg at build time (host afconvert) to PCM .wav resources.
    - fonts: WOFF2→TTF for Inter and story fonts.
 4. CI: xcodebuild for the app, swift test per package, fuzz smoke (60 s per target), ASan job. Coverage-guided libFuzzer needs the swift.org toolchain (Xcode 27 rejects -sanitize=fuzzer); until then codec-fuzz (deterministic structure-aware mutator under ASan) runs instead.

 Phase 1 — SignalCodecs: still & animated images (the core security deliverable)

 Order matches dependency and payoff. Step 0 of this phase is CodecCore/Grammar (the combinator library from the LangSec section) plus the zlib/Deflate grammar and decoder, since PNG, APNG and WOFF2 depend onit. Each decoder is then built as XGrammar.swift (spec syntax tables) + XDecoder.swift (consumes the AST), with hard limits (max 16k×16k, max frames, max output bytes), exhaustive conformance tests,grammar-generated property tests, a fuzz target seeded from the grammar generator, and a DecodedImage/AnimatedImage common output (RGBA8 + optional per-frame delay/dispose).

 ┌───────────┬───────────────────────────────────────────────────────────────┬────────────────────────┐
 │  Decoder  │                         Spec coverage                         │   Conformance corpus   │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │ PNG +     │ all colour types, 1–16 bit, Adam7, PLTE/tRNS/gAMA ignore,     │ PngSuite, APNG test    │
 │ APNG      │ acTL/fcTL/fdAT, dispose/blend ops; own Inflate (zlib) in      │ suite                  │
 │           │ CodecCore                                                     │                        │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │           │ baseline, extended, progressive (spectral selection +         │                        │
 │ JPEG      │ successive approximation), restart markers,                   │ libjpeg-turbo          │
 │           │ 4:4:4/4:2:2/4:2:0/gray, CMYK/YCCK (Adobe), EXIF orientation   │ testimages, ITU T.83   │
 │           │ (APP1 TIFF parse only)                                        │                        │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │ GIF       │ 87a/89a, LZW, interlace, GCE disposal/transparency, NETSCAPE  │ giflib tests           │
 │           │ loop                                                          │                        │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │ WebP      │ RIFF/VP8X, VP8 lossy (full intra decoder incl. loop filter),  │ libwebp test vectors   │
 │           │ VP8L lossless (transforms, colour cache), ALPH, ANIM/ANMF     │                        │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │ BMP / ICO │ 1–32 bpp, RLE4/8, bitfields, top-down; ICO with BMP or PNG    │ custom                 │
 │  / XBM    │ entries                                                       │                        │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │           │                                                               │ upstream               │
 │ Blurhash  │ encode (4×3) + decode                                         │ ts/util/*BlurHash*     │
 │           │                                                               │ vectors                │
 ├───────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
 │           │ JPEG baseline (quality table scaling, chroma subsampling),    │                        │
 │ Encoders  │ PNG (filters + own Deflate), WebP lossy q0.8 (VP8 intra       │ round-trip tests       │
 │           │ encoder — needed only by sticker creator; schedule in Phase   │                        │
 │           │ 7)                                                            │                        │
 └───────────┴───────────────────────────────────────────────────────────────┴────────────────────────┘

 Also in this phase: EXIF-orientation-aware scaling pipeline mirroring ts/util/scaleImageToLevel.preload.ts (levels 1600/2048/4096, size targets 1/1.5/3 MiB, dimension ladder3072→512), and the "image is animated → never re-encode (GIF) / flatten (WebP, APNG)" rules from ts/util/Attachment.std.ts.

 Phase 2 — SignalCore: account, database, link, receive, send 1:1

 1. Database: GRDB + SQLCipher, WAL, key in Keychain (replaces Electron safeStorage in app/main.main.tsgetSQLKey). Port the latest schema from DATABASE_SCHEMA.md as one initial migration (no legacy migrations), plus FTS5 on messages with unicode61 (port upstream's signal_tokenizer later). Typedrecord structs for conversations, messages, attachments, reactions, edited_messages, mentions, sessions/prekeys/… tables, items KV with the keys from ts/types/StorageKeys.std.ts.
 2. Protocol stores: implement LibSignalClient's SessionStore, IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SenderKeyStore over GRDB with the transactional "zone" semanticsof SignalProtocolStore.withZone (decrypt and persist atomically).
 3. Provisioning: Net.connectProvisioning → QR URL(sgnl://linkdevice?uuid&pub_key&capabilities=nopni,nopni2), ProvisionMessage decrypt (X25519 + HKDF "TextSecure Provisioning Message" + AES-CBC/HMAC, port of ProvisioningCipher.node.ts), device-nameencryption (DeviceName.proto), PUT v1/devices/link with account attributes, prekey/Kyber/last-resort upload, PNI identity handling (AccountManager.setPni). Install screen UI (Phase 3) drives it.
 4. Networking: SocketManager port (auth + unauth ChatConnection, keepalive, clock-skew, request queue), WebAPI endpoint table split exactly as upstream: CHAT_CALLS over the socket fetch,STORAGE_CALLS/CDN/resources over URLSession. Remote config (v2/config) + Net.setRemoteConfig bridge (LibsignalNetRemoteConfig.preload.ts).
 5. Receive pipeline: port MessageReceiver — envelope cache (unprocessed), sealed-sender unseal (sealedSenderDecryptToUsmc + trust roots), signalDecrypt/PreKey, groupDecrypt, Content dispatch forDataMessage, SyncMessage (all 22 sub-types), TypingMessage, ReceiptMessage, EditMessage, StoryMessage, DecryptionErrorMessage, PniSignatureMessage, SenderKeyDistributionMessage, NullMessage, CallMessage(queued for Phase 6). processDataMessage validation. Event model = Swift AsyncStream of the 33 events in messageReceiverEvents.std.ts.
 6. Send pipeline: OutgoingMessage (prekey bundle fetch via v2/keys, signalEncrypt, sealedSenderEncrypt, retries, 409/410 mismatched-device handling), sender certificates (v1/certificate/delivery),conversation job queue + send log tables for retry/resend, receipts (delivery/read/viewed) and typing.
 7. Contacts/profiles: profile fetch (v1/profile, access key / versioned credentials), profile crypto(port Crypto.node.ts AES-GCM helpers), CDSI via Net.cdsiLookup, contact sync + storage-service read of ContactRecord/AccountRecord/GroupV2Record (full storage service in Phase 4).
 8. Integration tests against packages/mock-server (start it from Node in a test fixture, point the client at localhost with the test certs, link via server.waitForProvision(), exchange messages withPrimaryDevice.sendText / waitForMessage).

 Phase 3 — SignalUI shell (1:1 visual port)

 Method: for every upstream component, open its Storybook story (pnpm storybook in Signal-Desktop/), capture reference PNGs light/dark, and build the SwiftUI twin against the generated tokens. Screenshottests compare the SwiftUI view to the Storybook capture at ≤1% pixel diff. Keep upstream's component names and tree so reviews map one-to-one.

 1. Design system (mirrors ts/axo): AxoButton, IconButton, Switch, Checkbox, Select, SegmentedControl,Tabs, Dialog/AlertDialog/ConfirmDialog, ContextMenu, DropdownMenu, Tooltip, Avatar (12 colours by hash % 12), Badge, Symbol (icon font), ScrollArea, Panel, Theme (system/light/dark + force-dark forcalling), DragRegion, fields, items/lists, status indicators. Typography: Inter at the Axo scale (title-large 24/32 … caption 11/14).
 2. Window frame: single main window (800×610 default, 300×200 min), hidden title bar with drag region, 80 px NavTabs rail (Chats/Calls/Stories/Settings), resizable NavSidebar, native menu bar fromapp/menu.std.ts (App/File/Edit/View/Window/Help, same shortcuts), dock badge, ShortcutGuide sheet with the ~50 shortcuts from ts/components/ShortcutGuide.dom.tsx.
 3. Left pane: LeftPane + the 8 LeftPaneMode helpers (Inbox, Search, Archive, Compose, ChooseGroupMembers, FindByUsername, FindByPhoneNumber, SetGroupMetadata), chat folders bar, conversation list rows(conversationList/*), search input, banners/dialogs (network status, update, relink, clock skew), megaphones.
 4. Conversation view: ConversationHeader, Timeline (virtualised, sticky date headers, scroll-down button, unread/mention indicators, typing bubble), TimelineItem → Message (bubbles, chat colours/gradients,quotes, image grid, link previews, stickers, audio player w/ waveform, documents, contacts, polls, reactions, edit history, delivery status, expire timer), the ~25 system *Notification rows,MessageDetail, ConversationHero, message request / select mode actions.
 5. Composer: attributed-text editor (NSTextView-backed) with mentions,bold/italic/strikethrough/monospace/spoiler, emoji auto-substitute, draft persistence, attachment staging, voice-note recording UI, Fun picker (emoji/GIF/sticker panels in ts/components/fun), quote,edit mode.
 6. Right-hand panels (ts/types/Panels.std.ts): ConversationDetails, AllMedia (gallery), ContactDetails,ChatColorEditor, GroupInvites, GroupLinkManagement, GroupPermissions, GroupMemberLabelEditor, MessageDetails, NotificationSettings, PinnedMessages, StickerManager, WhileMuted — with upstream'spush/pop animation.
 7. Install screen (QR, link-in-progress, error, update dialog), About, DebugLog, permissions popup,global modal container + toast manager, Lightbox.
 8. Settings as a tab (Preferences.dom.tsx pages): Profile, Account, General, Donations, Appearance, Chats (incl. chat folders), Calls, Notifications (incl. profiles), Privacy, Data usage, Internal. Backups page omitted.

 Phase 4 — Groups, storage service, attachments, stickers, previews

 1. Groups v2: port ts/groups.preload.ts — group master key → secret/public params, v2/groups* HTTPS withauth-credential presentations (groupCredentialFetcher), decrypt title/description/avatar, GroupChange apply + the ~25 build*Change builders, join via link, invite links, admin approval, banned members,announcement-only, groupChange.std.ts rendering. Sender-key sends with sealedSenderMultiRecipientEncrypt + group-send endorsements (ts/util/groupSendEndorsements.preload.ts, two SQL tables).
 2. Storage service: full storage.preload.ts + storageRecordOps port (manifest/items AES-GCM, recordIkm,merge/conflict rules for all 11 record types incl. ChatFolder, NotificationProfile, CallLink), write-back on local changes.
 3. Attachments: V2 crypto (AES-CBC+HMAC, 64-byte key, logPadSize padding, SHA-256 digest), incremental MAC via libsignal, CDN2/CDN3 TUS upload (tusProtocol.node.ts), download manager withpriorities/backoff (AttachmentDownloadManager), local re-encryption at rest, thumbnails (PNG 150 px) and blurhash via SignalCodecs, media quality levels from remote config, auto-download settings,quarantine xattr on save.
 4. Stickers: pack install/uninstall/favourites, manifest + sticker decrypt (deriveStickerPackKey, V1attachment decrypt), WebP/APNG via SignalCodecs, WebpSanitizer on outbound, Sticker manager panel.
 5. Link previews: linkify, fetch through the content proxy, OpenGraph/favicon parse (own HTML tokenizerlimited to <meta>/<link> as upstream), image ≤1 MiB through SignalCodecs; sticker-pack and group-link previews.
 6. Reactions, edits (edit history), delete-for-everyone/delete-for-me sync, pinned messages, polls, disappearing messages + timer sync, view-once, message requests, blocking, archive/mute/pin,nicknames/notes, safety numbers (Fingerprint), usernames (hash/reserve/confirm/link QR), key transparency (chat.keyTransparencyClient).

 Phase 5 — SignalCodecs: containers, video, audio (all Swift)

 ┌──────────────┬─────────────────────────────────────────────────────────────────────────────────────┐
 │  Component   │                                        Scope                                        │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │              │ ISOBMFF demux: ftyp/moov/trak/stbl, stts/ctts/stsc/stsz/stco/co64, edit lists,      │
 │ ContainerMP4 │ avcC/esds, fragmented MP4 not required; duration + avc1 check for stories           │
 │              │ (isVideoGoodForStories)                                                             │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │              │ Baseline/Main/High profile decoder: CAVLC + CABAC, intra/inter prediction,          │
 │ VideoH264    │ deblocking, B-frames, multiple reference frames, 8-bit 4:2:0. Output I420 → Metal   │
 │              │ texture (YUV→RGB in a shader). Must hit ≥30 fps 1080p on Apple silicon (SIMD +      │
 │              │ multithreaded slice/row decode)                                                     │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │ AudioAAC     │ AAC-LC (+HE-AAC SBR optional) decoder; ADTS and MP4 sample entry                    │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │ AudioMP3     │ MPEG-1/2 Layer III decoder; LAME-compatible encoder (VBR q7, ~90 kbps, Xing/LAME    │
 │              │ header) for voice notes                                                             │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │ Playback     │ AVAudioEngine PCM output (not a parser), waveform builder (100 RMS bins, port       │
 │              │ waveformBuilder.std.ts), scrubber                                                   │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │ Video        │ Lightbox/inline video player, poster frame (first frame → PNG), GIF-flag MP4 loop   │
 │ pipeline     │ playback in GIF and FunGif, Giphy picker (api.giphy.com MP4 renditions), outbound   │
 │              │ MP4 through libsignal Mp4Sanitizer                                                  │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │              │ Port ts/mediaEditor/* (crop, draw, text, stickers, time stickers, undo) on a        │
 │ Media editor │ Canvas-based SwiftUI editor, exporting JPEG (fix upstream's PNG-labelled-JPEG bug   │
 │              │ by labelling correctly)                                                             │
 ├──────────────┼─────────────────────────────────────────────────────────────────────────────────────┤
 │ Fuzzing      │ targets for MP4, H.264 NAL/slice, AAC, MP3                                          │
 └──────────────┴─────────────────────────────────────────────────────────────────────────────────────┘

 Phase 6 — Calling (ringrtc)

 1. Link libringrtc.a (native + prebuilt_webrtc, see Phase 0 step 2) through our C ABI crate, and write the Swift SignalRingRTC API against it, modelled on vendor/ringrtc/src/node/ringrtc/Service.ts (the TS layer Signal Desktop calls) rather than the iOS wrapper. Audio devices come from ringrtc/cubeb, as on Desktop. Register the Opus DRED asset (optional resource calling-dred_weights-*.bin).
 2. Port ts/services/calling.preload.ts (CallingClass): all RingRTC callbacks (handleOutgoingSignaling, handleSendHttpRequest → our HTTP, handleSendCallMessage[ToGroup], ring updates…), CallMessage routingfrom the receive pipeline, call-link zkgroup credentials (ts/util/callLinks/*), group membership proofs, peeking, ringing, call history + CallEvent/CallLogEvent/CallLinkUpdate syncs.
 3. Video: camera capture via AVCaptureSession → I420 → VideoFrameSender; remote frames via VideoFrameSource.receiveVideoFrame (RGBA) → Metal. Constants from ts/calling/constants.std.ts(960×720@30, 640×480 group, 2880×1800@5 screen share, SVC L3T3_KEY/L1T3).
 4. Screen share via ScreenCaptureKit (what @indutny/mac-screen-share wraps), source picker modal,floating 44 px "presenting" controller window, screen-recording permission flow. Mute-state via AVAudioApplication.
 5. UI: CallManager, CallingLobby, CallScreen (controls, header, toasts, reactions burst, raised hands, participants list/menu, pending participants, admin approve/deny), GroupCallRemoteParticipants grid +overflow, DirectCallRemoteParticipant, CallingPip, IncomingCallBar, Calls tab (CallsList, new-call, call-link details/edit/add-name), CallQualitySurvey, ConfirmLeaveCall, call-diagnostic window.

 Phase 7 — Remaining parity

 Stories (tab, pane, viewer, creator incl. text stories, send modal, distribution lists, views/replies,settings), chat folders, notification profiles + system notifications (UNUserNotificationCenter, name and message / name only / count modes, draw attention, badge rules), spell-check (NSSpellChecker), donations (Stripe/PayPal flows, receipts, badges), username link QR card, PDF export window, sticker creator window (needs WebP encoder), plaintext export, crash reports (own minidump path via libsignal Minidump),debug log upload (debuglogs.org), auto-updater (Ed25519-signed feed at updates.signal.org/desktop, differential updates optional; own downloader, no Sparkle), content protection/screen security,display-sleep prevention, start-at-login, Internal settings page.

 Phase 8 — HEIC and AVIF decoders

 1. HEIF container (ISOBMFF meta/iprp/ipco/iloc/iinf, grid tiles, irot/imir, alpha aux) shared with ContainerMP4.
 2. HEVC intra decoder (Main profile, 8-bit 4:2:0): CABAC, 35 intra modes, transform skip, SAO, deblocking — I-slice only, tile-parallel.
 3. AV1 intra decoder (Main profile, 8/10-bit 4:2:0 and 4:4:4): OBU parse, symbol decoder, intra tools incl. CfL, palette, intrabc, loop filter/CDEF/loop restoration, film grain — key-frame only.
 4. Hook both into the display allowlist and the send pipeline (HEIC → JPEG at q0.75 as upstream's heicConverterWorker).

 Phase 9 — Hardening and release

 App Sandbox + hardened runtime, entitlements (network client, camera, mic, screen capture), Developer IDsigning + notarisation, per-decoder fuzz corpora checked into Packages/SignalCodecs/Fuzz/corpus, continuous fuzzing job, -enable-experimental-feature StrictMemorySafety where available, decoder sandbox: done in Phase 3 step 0 (see "Decision: all parsing of incoming media runs in a sandboxed XPC service"), threat-model doc.

 Verification

 - Codecs: conformance suites listed in Phase 1/5/8 (bit-exact or PSNR thresholds for lossy), grammarround-trip tests (generate → parse is identity; every validate predicate has a failing fixture), fuzz 24 h per target before each release seeded from grammar-generated corpora, ASan/UBSan/TSan runs of thetest suites, differential tests against libpng/libjpeg-turbo/libwebp/ffmpeg outputs in CI (test-only dependencies).
 - Protocol: swift test integration suite against packages/mock-server covering linking, 1:1 and group messaging, storage sync, stickers, attachments (CDN3 TUS), call links and group calls (mock SFU); plusmanual end-to-end against Signal staging with a real phone.
 - UI: Storybook-capture screenshot tests per component (light/dark), accessibility audit viaAccessibility Inspector, keyboard-shortcut parity checklist from ShortcutGuide.dom.tsx.
 - Performance: 1080p H.264 ≥30 fps, 12 MP JPEG decode <150 ms, app cold start <1 s with 50k messages,timeline scroll at 120 Hz.
 - Security gate: lint that no target outside SignalRingRTC/vendor links ImageIO, CoreImage, VideoToolbox, AudioToolbox, AVFoundation decoders, or UIImage/NSImage(data:); otool -L check in CI.

 Critical upstream files to keep open while porting

 ts/textsecure/MessageReceiver.preload.ts, ts/textsecure/SendMessage.preload.ts, ts/textsecure/WebAPI.preload.ts, ts/textsecure/SocketManager.preload.ts,ts/textsecure/AccountManager.preload.ts, ts/SignalProtocolStore.preload.ts, ts/groups.preload.ts, ts/services/storage.preload.ts, ts/services/storageRecordOps.preload.ts, ts/AttachmentCrypto.node.ts,ts/services/calling.preload.ts, ts/sql/Server.node.ts + DATABASE_SCHEMA.md, ts/types/StorageKeys.std.ts, ts/components/conversation/Message.dom.tsx, ts/components/LeftPane.dom.tsx,ts/components/Preferences.dom.tsx, ts/axo/AxoTokens.std.ts, stylesheets/_variables.scss, protos/*.proto, packages/mock-server/src/*.

 Sequencing summary

 Phase 0 → 1 → 2 → 3 run largely in parallel after Phase 0 (codecs, core, UI are independent packages).Phases 4–7 build on 2+3. Phase 5 is needed before the GIF picker and voice notes ship. Phase 6 depends on the Phase 0 ringrtc spike succeeding. Phase 8 is last because HEIC/AVIF are not needed for a usableclient. First milestone to aim for: "link, receive and send text + images with a pixel-matched chat window" = Phases 0, 1 (PNG/JPEG/GIF/WebP), 2 and 3 (steps 1–5).


## Status and decisions after first implementation session (2026-11-04)

- **Donations are out of scope too (user decision, 2026-11-04):** gift badge messages, the Quote gift-badge variant, the release-note "Donate" call-to-action, donor badges on avatars (TimelineMessage BadgeInGroup, the two TypingBubble badge stories) and the Preferences Donations page are omitted with their stories. RemoteMegaphone stays: it is generic; only its story content is about donating.
- **Payments / MobileCoin are out of scope (user decision, 2026-11-04).** Omit payment UI (message payment notifications, quote payment text, payment settings) and the related stories (TimelineMessage PaymentNotification, Quote Payment). Payment messages need no special receive handling beyond what upstream does for unsupported content.

- **Fuzzing is deprioritised (user decision).** Parsers are memory-safe Swift, so fuzzing is not a gate for any phase. The existing `codec-fuzz` tool is kept but not extended; ignore the fuzz items in Phases 1, 5, 9 and in Verification.
- Phase 0 step 1 done: `vendor/libsignal` (v0.106.0) builds `libsignal_ffi.a` for aarch64-apple-darwin; the Swift package exposes Net, ChatConnection, ProvisioningConnection, zkgroup, IncrementalMac and the sanitizers on macOS.
- Phase 0 step 2 done (build only): `vendor/ringrtc` (v2.73.0) builds `libringrtc.a` for aarch64-apple-darwin with `native,prebuilt_webrtc` (prebuilt WebRTC 8037a mac-arm64 fetched; needs GNU coreutils for `grealpath`). Not yet verified: a live call (`make direct`).
- New risk for the app link step: ringrtc depends on libsignal **v0.99.1** (zkgroup) while the app uses **v0.106.0**. Linking two Rust staticlibs into one binary can produce duplicate Rust std / crate symbols. Check at the first app link; options are building both through one Cargo workspace that emits a single staticlib, or bumping ringrtc's libsignal pin.
- Phase 1 step 0 done: `Packages/SignalCodecs` with the grammar combinator library, Deflate/zlib, and PNG/APNG (grammar + decoder). Tests pass: unit and policy tests, PngSuite (162 valid decode, 14 corrupt rejected, Adam7 equals non-interlaced), and differential against ImageIO on 130 files.
- Phase 1 done (2026-11-04): JPEG (bit-exact with djpeg), GIF, WebP VP8/VP8L/ALPH/animation (bit-exact with dwebp / WebPAnimDecoder), BMP/ICO/XBM, blurhash (bit-exact with the C reference), PNG and JPEG encoders (JPEG byte-identical to cjpeg -baseline). `swift test` in Packages/SignalCodecs: all 16 differential/conformance suites and the unit suites pass; Tools/lint-codecs.sh ok. Not optimised yet; performance work is part of the later perf targets.

## Decision (2026-11-04): all parsing of incoming media runs in a sandboxed XPC service with no network access

User request: "move parsing of incoming formats into an MacOS entitlement with no network access". This replaces the Phase 9 item "decoder work moved into an XPC service" and is pulled forward to **Phase 3 step 0**. It lands together with the first app target, before any UI renders untrusted media.

- **Service:** `SignalMediaDecoder.xpc`, bundled at `SignalSafe.app/Contents/XPCServices/`. It is built from a new `Packages/SignalMediaService` package: a service executable that links only SignalCodecs, plus a small `MediaXPCInterface` module shared with the app. The service never links LibSignalClient, GRDB, SignalCore or any networking code.
- **Entitlements:** the service's only entitlement is `com.apple.security.app-sandbox = true`. It gets no `network.client`, `network.server`, file-access, camera, mic or Keychain entitlements, and runs under the hardened runtime. With App Sandbox and no network entitlement, the kernel denies every outbound and inbound socket. The service also cannot read the app's container, so it cannot reach the SQLCipher DB or the Keychain key.
- **Data flow:** the main process downloads, verifies the digest and incremental MAC, and decrypts. It then sends **plaintext bytes** to the service over NSXPCConnection, so attachment keys never enter the service. The service returns only flat results: RGBA frames in shared memory (IOSurface / xpc_shmem) with dimensions and delays, PCM buffers, or plain structs of strings for link previews. The main process re-validates every result, for example that width × height × 4 equals the buffer size and that values are within limits, before using it.
- **Formats routed through the service:** images (PNG/APNG, JPEG, GIF, WebP, BMP/ICO/XBM, later HEIC/AVIF), blurhash decode, and EXIF orientation. Audio (MP3, AAC) and video (MP4 demux, H.264) follow in Phase 5. Also the link-preview HTML/OpenGraph parser, and the re-encode path for sending (scale, then JPEG/PNG/WebP encode), because it decodes user-chosen files. Protobuf parsing of decrypted `Content`, groups and storage records stays in the main process, because it needs keys and its parser is generated SwiftProtobuf.
- **Failure model:** a crash, a timeout (watchdog per request), or an over-limit result counts as "undecodable attachment", and the service is relaunched. One long-lived instance handles all requests. A per-conversation or per-request instance can be added later if wanted.
- **Enforcement:** a lint and link check confirm that the app binary, SignalCore and SignalUI do not import decoder modules. Only `MediaXPCInterface` is allowed, and `nm` on the app binary must show no `ImagePNG`/`ImageJPEG`/… symbols. The service's entitlements are checked in CI with `codesign -d --entitlements`. An integration test asks the service to open a TCP socket to 127.0.0.1 and to read the app's DB path, and asserts both fail with EPERM.
- **Development before the app exists:** `SignalMediaService` gets an in-process fallback used only by unit tests. Debug app builds use the real XPC service.

## Status (2026-11-04): Phase 2 steps 1-5 done in Packages/SignalCore

- **Database:** SQLCipher via GRDB, key in the Keychain, upstream schema 1870 with 51 tables, FTS5, 99 indexes and 9 triggers. FTS5 shadow tables are left for SQLite to create.
- **Protocol stores:** all six LibSignalClient stores are backed by the upstream tables. A decrypt and the storing of its result share one write transaction.
- **Linking:** provisioning socket, QR URL, ProvisionMessage decrypt, encrypted device name, link request, then signed, last-resort and one-time pre-key upload for both ACI and PNI. The account is stored under the upstream item keys.
- **SocketManager:** authenticated and unauthenticated libsignal-net chat connections, with reconnect and backoff.
- **Receive pipeline:** cache in `unprocessed`, ack, then one transaction that covers sealed-sender unseal with trust-root check, decrypt, unpad, Content dispatch and persistence. Handled kinds are DataMessage, SyncMessage.Sent, receipts, typing, edits, DecryptionErrorMessage and sender-key distribution.
- **Tests:** `swift test` runs 26 tests in 6 suites. LinkDeviceTests and ReceiveMessageTests run against upstream's in-tree Signal-Desktop/packages/mock-server. Tools/build-mock-server.sh copies it to Tests/MockServer/.mock-server, pins upstream's pnpm-lock versions (libsignal-client 0.106.0), and builds it with npm, because upstream's pnpm engines pin rejects Node 26. Tools/vendor-patches/libsignal-aes-cbc.patch bridges signal_crypto AES-256-CBC to Swift.
- **Strict memory safety:** every target in both packages builds with `-strict-memory-safety`, with `-Werror StrictMemorySafety`. The codec libraries contain zero `unsafe`. SignalCore has one, the Keychain read through SecItemCopyMatching. Tools/lint-codecs.sh enforces both.
- **Phase 2b leftovers:** retry requests for failed decrypts, sending and replies (so the receive path sees whisper messages in integration), profiles, CDSI, storage-service read, and the remaining sync-message kinds.

## Status (2026-11-04): Phase 2 steps 6-8 done in Packages/SignalCore

- **Send pipeline** (`Messaging/MessageSender.swift`):
  - Devices with a live session are encrypted for in one write transaction; with no session, every pre-key bundle is fetched from `v2/keys/<id>/*`.
  - Sealed sender is used when the contact's profile key is known. The request goes over the unauthenticated socket with Unidentified-Access-Key; a 401 falls back to an authenticated send.
  - 409: archive extra devices, fetch the missing ones. 410: archive stale devices and refetch them.
  - Identity changes: a contact verified with a new key blocks sending; otherwise the new key is accepted, sessions are archived and a `keychange` message is inserted.
  - Sender certificates are fetched, validated against the trust roots and our identity, and cached under the upstream item keys.
  - Every send is written to the upstream send log tables.
- **Job queue** (`Jobs/JobQueue.swift`): persistent, over the upstream `jobs` table. A job is inserted in the same transaction as the change that needs it. Jobs run in order, retry with exponential backoff, and have a failure hook (a failed message gets send status Failed).
- **Messenger** (`Messaging/Messenger.swift`):
  - `sendText` sends the DataMessage to the contact and a SyncMessage.Sent transcript to our other devices.
  - Delivery receipts are queued with every received message.
  - `markRead` / `markViewed` send read/viewed syncs, plus receipts when the read-receipt setting is on.
  - Typing indicators are sent online-only and are not written to the send log.
  - Retry requests (DecryptionErrorMessage) are answered from the send log, or with a NullMessage if the payload is no longer logged.
  - Sync requests (contacts, blocked, configuration, keys) go to the primary.
- **Receiver additions:** profile keys from DataMessage; read/viewed syncs; configuration, keys and blocked syncs; contacts sync (queues a download job); FetchLatest(storage) (queues a storage read).
- **Profiles** (`Profiles/ProfileService.swift`): versioned `v1/profile` fetch with the access key, AES-GCM name/about decrypt, access-key verifier giving the sealed-sender mode, identity handling as on send.
- **CDSI** (`Contacts/ContactDiscovery.swift`): auth from `v2/directory/auth`, `Net.cdsiLookup` with ACI + access-key pairs, results merged into conversations. The mock server has no CDSI enclave, so tests cover request building and merging with an injected lookup, plus the real `Net.cdsiLookup` path failing cleanly.
- **Contact sync** (`Contacts/ContactSync.swift`): CDN download over pinned-root HTTPS (`Net/HTTPClient.swift`), attachment v2 decrypt (`Attachments/AttachmentCipher.swift`), and a bounds-checked parser for the varint-framed ContactDetails stream.
- **Storage service read** (`StorageService/StorageServiceReader.swift`):
  - Manifest and item keys support both recordIkm/HKDF and the legacy HMAC derivation.
  - ContactRecord, AccountRecord and GroupV2Record are merged remote-wins.
  - Other record types are kept in `storage-service-unknown-records`.
  - Incremental reads use `manifest/version/<n>`.
- **Tests:** `swift test` runs 56 tests in 13 suites, including SendMessageTests, ReceiptTests, ProfileTests, StorageReadTests, ContactSyncTests, ContactDiscoveryTests and JobQueueTests.
- **Mock-server certificate:** Tools/build-mock-server.sh re-issues the mock server's TLS leaf from its own CA with 397 days and EKU serverAuth, because Apple's TLS policy rejects upstream's 100-year leaf.
- **Left for Phase 4:** storage-service write-back and the remaining record types, group sends (sender key + endorsements), profile upload/avatars, and CDSI token persistence.

## Phase 3 working method (2026-11-04)

- **Reference pipeline:**
  - `Tools/build-storybook.sh` copies Signal-Desktop to `.cache/storybook-desktop`. It fetches the pinned Node 24.22.0 (SHA-checked) and pnpm 11.24.0, then runs `pnpm install` and `build:storybook`: 2,043 stories.
  - `Tools/capture-storybook.mjs` drives Playwright Chromium at 2× with an sRGB profile and animations skipped. It captures each story in `Tests/SignalUITests/stories.txt`, in light and dark, clipped to the story root, into `Tests/SignalUITests/References/<id>.<theme>.{png,json}`.
  - `--all <regex>` also writes DOM and computed-style dumps to `.cache/storybook-refs` for porting.
  - `--tokens` has Chromium resolve every CSS custom property in both themes. `color-mix(in srgb)` gives exact sRGB, and shadows are resolved layer by layer.
- **Generators:**
  - `Tools/gen-tokens.mjs` writes `AxoTokens.generated.swift`: 80 colours, 11 shadows, radii, blurs, motion.
  - `Tools/gen-symbols.mjs` writes `AxoSymbolDefs.generated.swift`: the Signal Symbols tables.
  - `Tools/gen-fonts.sh` converts the trusted bundled WOFF2 fonts to TTF with fontTools at build time. This replaces the planned Swift WOFF2 tool. Fonts never come from the network.
- **Text:** `CSSText` lays text out like Chromium: CoreText measurement at fractional widths, CSS line boxes with half-leading, `letter-spacing` after every character, ellipsis truncation. It draws with CoreText, which Chromium also uses for glyphs on macOS. SwiftUI `Text` rounds sizes to the pixel grid and drifts off the reference.
- **Font weights:** upstream's @font-face rules give 600 and 700 → Inter SemiBold, 500 → Medium. The Inter-Bold file has an invalid weight and is never used.
- **Screenshot tests:**
  - `Snapshot.assertMatches(view, story:, theme:)` renders with `ImageRenderer` at 2× on the Storybook background. Comparison is a Swift port of pixelmatch (YIQ, threshold 0.1, anti-alias detection). It passes at ≤1% differing pixels and writes actual/expected/diff PNGs to `.build/snapshot-failures`.
  - Run with `swift test -c release`, because the debug build compares about 100× slower.
  - Each test file also contains a SwiftUI twin of the story's own layout markup.
- **First result:** AxoButton `Basic` differs by 0.26% (light) and 0.23% (dark).
- **Progress (2026-11-04, later):**
  - Axo components merged into Packages/SignalUI: Button, IconButton, Switch, Checkbox, Badge, Avatar (token parts), Dialog, AlertDialog, ConfirmDialog, DropdownMenu, ContextMenu (with BaseMenu and the Popper layer host), Select, SegmentedControl, Tabs, StackedButton, MediaButton, fields, RadioGroup, items/lists, ContactName.
  - `swift test -c release`: 82 tests in 28 suites, about 150 stories × 2 themes, all ≤1% (worst 0.52%). Portal stories are also held to ≤1% inside the portal rects.
  - Blink's text baseline rule is now matched exactly in CSSText.
  - Still running: status/scroll/panel/message/chat components, the SignalI18n package, and legacy shared components.

### Phase 3 step 2 progress (2026-11-04)
- ShortcutGuide + ShortcutGuideModal (stories default/mac ≤0.46%), NavSidebar (+ LeftPaneWidth, WidthBreakpoint, back button, search header, empty state; verified later through the LeftPane stories), Inbox, App, TitlebarDragArea, NavTabs drag-area padding.
- MainMenu: app/menu.std.ts template (+ updateForMac) as data → NSMenu; MainMenuTests check labels, order, accelerators and role selectors.
- App target `App/SignalSafe` (AppKit lifecycle hosting SignalUI): 800×610 hidden-title-bar window (min 300×200), zoom 1.2^level, dock badge, hide on close / show on reopen. `Tools/build-app.sh` → App/SignalSafe/.build/SignalSafe.app (ad-hoc signed). The inbox shows empty tabs until SignalCore is wired in.

### Phase 3 step 3 progress (2026-11-04)
- Left-pane banners: LeftPaneDialog (+ icon background, progress bar), DialogNetworkStatus, DialogRelink, DialogClockSkew, DialogExpiredBuild, DialogUpdate (all states), UnsupportedOSDialog, LeftPaneBanner; megaphones: Megaphone, PinReminderMegaphone, RemoteMegaphone, UsernameMegaphone.
- ConversationList with rows: archive button, header, ConversationListItem / BaseConversationListItem (unread indicators, status icons, typing animation, mute icon, drafts), ContactListItem / ContactCheckbox on ListTile, StartNewConversation, UsernameSearchResultListItem, loading skeleton, MessageSearchResult. All 36 ConversationList and 14 MessageSearchResult stories ≤1%.
- Shared infrastructure: CSSText runs (rich text via `<I18n>` tags, inline backgrounds, strikethrough, line-clamp, Chromium line breaking, inline emoji boxes from the Signal emoji fonts converted CBDT → sbix by Tools/gen-emoji-fonts.py), BodyRanges + MessageTextRenderer (mentions, formatting, spoilers, search highlights), PixelImage (RGBA through a Metal shader: no ImageIO, no pointer APIs) with BundledImage (Tools/gen-images.mjs), deterministic Storybook captures (seeded Math.random, frozen clock, emoji font served locally).
- Next: SearchInput / LeftPaneSearchInput, LeftPaneChatFolders, the 8 LeftPaneMode helpers and LeftPane itself (50 stories), CaptchaDialog / CrashReportDialog.
- LeftPane with all 8 modes (Inbox, Search, Archive, Compose, ChooseGroupMembers, FindByUsername, FindByPhoneNumber, SetGroupMetadata), dialogs ordering, username banners, server alerts (critical / warning idle primary device), CaptchaDialog, CrashReportDialog, chat folders bar, conversation context menu (AxoDropdownMenu/AxoContextMenu gained hover submenus), SearchInput / LeftPaneSearchInput, CountryCodeSelect (+ Tools/gen-country-codes.mjs), DisappearingTimerSelect, AvatarPreview (empty state). 46 of 50 LeftPane stories ≤0.14%; the 4 backup-media-download stories are out of scope (no backups / no history import).
- Known subsets to revisit: phone numbers (PhoneNumberParsing: E.164 + NANP only, until libphonenumber metadata is ported), duration text (English humanize-duration only), ChooseCountryCodeModal not ported yet, chat folders bar and row context menu have no upstream story (unit-tested only).

### Phase 3 step 4 progress (2026-11-04)
- Message text: Emojify (12 stories, plus the two tens-of-thousands stress stories), Linkify (7, linkify-it 5.0.2 port matching the JS oracle), AddNewLines (4), MessageBody (17): links, jumbomoji (1–5 emoji → 56/48/40/36/32), AtMention pills, formatting (bold/italic/strike/mono/spoiler, nesting), "..." + Downloading / Message too long / Read more / Download Full Message. 16 of 17 MessageBody stories ≤1%; zalgo-text is held at ≤6% (3.9–4.6% now: Chromium's per-cluster font fallback is matched, the combining-mark stacks are HarfBuzz mark/mkmk positioning vs CoreText's).
- CSSText gained: inline-block runs (padding/border/background via kerned no-break spaces), CSS hanging whitespace (no-break spaces don't hang), Blink's liga/clig/calt-off under letter-spacing, decorations that skip emoji boxes, strikethrough on whole CSS pixels. Monospace is Menlo (Chromium has no `ui-monospace`).
- ContactName (+ GroupMemberLabel pill, FunStaticEmoji; 8 stories), TypingAnimation (2), MessageBodyReadMore (9, graphemeAndLinkAwareSlice), MessageTimestamp (2), ExpireTimer (5), LastSeenIndicator (2), ScrollDownButton (2), SystemMessage (3), TimerNotification (5), SafetyNumberNotification (2), VerificationNotification (5), ProfileChangeNotification (4), ChangeNumberNotification (2), JoinedSignalNotification, ResetSessionNotification, TitleTransitionNotification.
- CSSText: emoji are line-break class ID (breaks around them), CSS white-space collapsing (MessageBody), configurable width tolerance (exact 1/64px for max-width containers).
- Emoji raster parity (fixed 2026-11-05): boxed emoji (FunInlineEmoji) are drawn from Signal Emoji's sbix strike (32px up to 32 device px, else 64px) rendered 1:1 into a layer and scaled with low (bilinear) interpolation, at the box's left edge rounded half up to a whole CSS pixel (`contain: strict` boxes; measured in Chromium: 7.48 → 7, 10.5 → 11). `CSSTextLayout.drawLine` draws every CoreText line (CSSText, AxoInlineFlow): each box is its own CTRun (`EmojiBox` attribute), hidden-spoiler boxes are skipped, and colour glyphs in plain text take the text colour's alpha (Skia modulates them; CoreText draws them opaque). `isEmoji` is upstream's `Emoji.isEmoji` (emoji-data parents and skin-tone variants), so a bare 🏝 stays text. Emoji left as text (past Emojify's 5000, or outside Emojify) are drawn the way Skia places text glyphs: x quantised to a quarter device pixel (half up) on a whole-pixel baseline, from the strike bilinearly, with the text colour's alpha. All emoji-dense notification and read-more stories, and both 40000-emoji stress stories (0.1–0.8%), are ≤1% without tolerances. Chromium paints a box's background/shadow, `<img>` object-fit rects and the contained emoji boxes at whole CSS pixels: layout here is in CSS pixels, snapped when painted.
- ChatSessionRefreshedNotification, DeliveryIssueNotification (3), ConversationMergeNotification (3), PhoneNumberDiscoveryNotification (2), UnsupportedMessage (4), InlineNotificationWrapper (3) + MessageSelectCheckbox. AxoInlineFlow (AxoChatEvent bodies) draws emoji boxes; its line-clamp drops trailing graphemes until the ellipsis fits and draws the next line into the body's 4px padding (`py-1 -my-1` under `overflow: hidden`), as Chromium does.
- TypingBubble (7 of 9 stories; the 2 badge stories wait for Avatar badges), CallingNotification (20), GroupV2Change (28; ts/groupChange.std.ts ported as GroupChangeRenderer, story fixtures extracted to Fixtures/groupv2change-stories.json), GroupV1Migration (8), CollapseSetViewer (15).
- ChatSessionRefreshedDialog, DeliveryIssueDialog (floating dialog header, illustrations rasterised by Tools/gen-images.mjs). AxoButton: `min-w-fit` inside dialog action groups; AxoDialog.Action autoFocus; Header(focusesClose:).
- ConversationHeader (16 stories): header content, call buttons (Both / JustVideo / Join, in-another-call), overflow menu (HeaderDropdownMenuContent), TimelineWarning, CollidingAvatars, LeaveGroupConfirmationDialog, CannotLeaveGroupBecauseYouAreLastAdminAlert. AxoAlertDialog.Ok takes the initial focus.
- ConversationHero (20; SharedGroupNames, GroupMembersNames, GroupDescription, Avatar `signalOfficial`), MessageRequestActions (8) + MessageRequestActionsConfirmation, MandatoryProfileSharingActions (2), GroupV1DisabledActions, GroupV2PendingApprovalActions.
- AxoModalStack: a window-level modal layer (`.axoModalHost()` at the app root; views present dialogs through `\.axoModalStack`). The full global modal container is step 7.
- Arabic line metrics (fixed 2026-11-05): Blink letter-spaces by script run, not per character; neutral characters (spaces, digits, punctuation) and marks take the run's script, and cursive-script runs get no letter-spacing (`cursiveScriptMask`). plain-rtl-message is ≤1% (0.94%).
- Message core (Components/Conversation/Message/): Message (row, group avatar, error column, bubble container with chat colours, collapsed radii, author, text with inline / bottom metadata via MessageTextMetadataSpacer, deleted-for-everyone), MessageMetadata (time / error states, pin, edited, SMS, timer, spinner, status icons). 34 of 159 TimelineMessage stories ≤1% (the "click for details" error stories were recaptured with CAPTURE_REMOUNT: their stale-width captures are gone). CSSText gained `\.cssTextWrapWidth` (exact block wrap width for sizing and drawing). Outgoing gradients are background-attachment: fixed (\.chatColorViewport); text dir=auto alignment.
- Quote (Components/Conversation/Quote.swift): all 39 in-scope Quote stories ≤1% (worst 0.44%): the 36 standalone ones (Quote Payment omitted) plus three in a message (GiftBadge, MessageNotFound, IncomingOutgoingColors); also TimelineMessage `quote` (37 of 159 now, with long-body-can-be-downloaded and custom-color).
  - Covers author / label / story-reply author, the 2-line clamped body, type labels, the generic file, payment, thumbnails (cover) with the play icon, the icon circles, gift thumbnail, close button, reaction emoji and the reference warning.
  - Solid backgrounds are css-lighten 0.6 / css-darken 0.4 in HSL.
  - Upstream quirk, matched: gradient quotes have no background, because `light-dark()` with gradient images is invalid in Chromium.
  - CSSText gained `breakWord` (overflow-wrap: break-word), used by quote and message text.
  - The quote's author line box is the inherited strut: 20px standalone, 0 in a message.
  - Bottom metadata is flex-end, and its margin collapses with the quote's when the text is empty.
  - Tools: gen-icons also takes images/movie.svg; gen-images rasterises generic-file.svg and gift-thumbnail.svg (at 54px).
- Attachments (Components/Conversation/Message/MessageAttachment.swift, ConversationImage.swift, ImageGrid.swift):
  - The generic file row (FileThumbnail with extension and dangerous badge, AttachmentStatusIcon, size, metadata in the row) and tap-to-view (icon states, View Once Photo / Video / Media, Viewed, the not-available block): 21 TimelineMessage stories ≤1% (56 of 158 in scope).
  - Image (ConversationImage: cover image or blurhash, download / progress / play / undownloadable overlays, caption mark, bottom and dark overlays, text, border, curves): all 21 Image stories ≤1% (worst 0.43%).
  - ImageGrid (1–5+ tiles, curves, AttachmentDetailPill, download pill): all 36 ImageGrid stories ≤1% (worst 0.16%). The tests read the stories' ImageGrid props from Fixtures/imagegrid-stories.json, evaluated from the story file with a recording JSX factory.
  - formatFileSize uses filesize.js SI symbols ("10 kB").
  - Blurhash (SignalCodecs) no longer range-checks DC / AC values, matching the C and JS references (the Image Blurhash story's hash has DC > 0xFFFFFF). SignalUI decodes only the trusted default blurhashes; a message's own blurhash comes decoded from the media service.
- TimelineMessage attachment stories now render from the stories' own props: Tests/SignalUITests/Fixtures/timelinemessage-stories.json, all 159 stories' TimelineMessage props evaluated from the story file. Author names come from timelinemessage-authors.json, the seeded names the captures show. Covered so far: images, videos, multiple images, too-large / missing-dimension images, broken images and videos, GIFs (8 stories, paused first frame, reduced motion as captured) and attachment-too-big (4 stories). 30 stories ≤1%, 86 of 158 TimelineMessage stories in scope.
  - signal-release-note-message (fixed 2026-11-05): the release-note class forces only the background colour, so an outgoing gradient chat colour (a background image) still paints over it. 0.17%.
  - broken-video (fixed 2026-11-05): Blink pixel-snaps an `<img>`/`<video>` object-fit content rect to whole CSS pixels (page coordinates, edges rounded half up); `PixelImage(snapsContentRect:)` does the same for message images and the Lightbox video frame (not for CSS `background-size` images such as quote thumbnails). 0.07%, and 47 other image stories improved.
  - Test speed: the SignalCodecs targets and the SignalUI test target build with -O in debug as well. Reference PNG decoding went from 13 s to 0.2 s for a tall story, and a 36-snapshot suite from 40 min to 24 s.
- Link previews (MessageLinkPreview: full-size image grid or 72px thumbnail, title / description clamps, domain • date footer, sticker-pack previews with "View Pack"), stickers (200px via ImageGrid, 300px author line), and shared contacts (EmbeddedContact + ContactAvatar, AxoAvatar.Image): 34 more fixture stories ≤1%. TimelineMessage is at 120 of 158 in scope.
  - Upstream rules matched along the way:
    - images aren't clipped to their curves (only cropped tiles are);
    - attachment status keys on `url`, not `path`;
    - set widths (grid, sticker, contact) are the content box's;
    - margins collapse between author / quote / attachment / preview / action / metadata.
- Reactions (MessageReactions, grouped and ordered like useGroupedAndOrderedReactions), jumbomoji up to 5 (no bubble) and audio (MessageAudio: PlaybackButton, 47-bar Waveform, countdown, unplayed dot) are done. TimelineMessage is at 137 of 158 in scope.
  - Audio waveforms for the tests come from Tools/gen-audio-waveforms.py: ffmpeg decode at 44.1 kHz plus a port of waveformBuilder; it matches the capture's bars to 0.02px. In the app they will come from the media service (Swift MP3/AAC, Phase 5).
  - The extractor now has real Emoji, durations and enum values, and getDefaultConversation keeps the story's overrides.
  - PixelImage copies pixels at an exact 1:1 mapping.
- TimelineMessage done (2026-11-05): all 148 in-scope stories ≤1% with no tolerances. The 11 payment and donation stories are left out (out of scope). Polls, story replies, multi-select, tap-to-view and undownloadable text attachments are covered too. AttachmentPartsTests covers the pills, status icons, file thumbnails and ImageOrBlurhash.
- TimelineItem (Components/Conversation/TimelineItem.swift):
  - Dispatches each item to a message, a collapse set, or its notification inside InlineNotificationWrapper. An unknown type renders ErrorBoundary's fallback.
  - New notification views: UniversalTimerNotification, MessageRequestResponseNotification, PinnedMessageNotification, ErrorBoundaryNotification, and the legacy GroupNotification. SystemMessage gained `paragraphs:` (the further `<p>` blocks).
  - All 3 captured stories ≤1% (MissingItem renders nothing). The Notification story's payment rows are cut out of its capture with Tools/splice-reference.py.
- Timeline (Components/Conversation/Timeline.swift):
  - The hero, the last-seen indicator, the items, the typing bubble, the floating date header, the scroll-down buttons and the Signal-chat chip.
  - Width breakpoints set the message max width.
  - Visibility and scroll state come from the ScrollView. Static rendering lays the content out at rest, scrolled to the bottom.
  - Also new: TimelineFloatingHeader (3 stories), TimelineDateHeader and TimelineDate (formatDate).
  - Timeline stories ≤0.24%, with the payment rows (id-15 to id-19) spliced out. Five of the nine stories capture identical pixels. WithInvitedContactsForANewlyCreatedGroup waits for NewlyCreatedGroupInvitedContactsDialog (step 7 modals).
- MessageDetail (6 stories ≤0.17%; AxoContactList titles take inline glyphs, items a value view; formatDateTimeLong; ExpirationTimer `largest:`).
- ReactionViewer (4) and ReactionPicker / ReactionPickerPicker (2), all ≤0.28%. The pickers' first button takes focus on open, with Chromium's `outline: auto` ring around the button and the lifted emoji.
- FunStaticEmoji over 16px: the glyph baseline sits at size/2 + 0.25 + (A − D)/2 (Signal Emoji's hhea metrics, ascent 1em and descent 0.3125em, each rounded). This moved the 18px and 48px emoji up by about 1px.
- ContactSpoofingReviewDialogPerson (4) and ContactSpoofingReviewDialog (5, with its Delete / Block confirmations and RemoveGroupMemberConfirmationDialog), all ≤0.85%.
- Timeline: the four duplicate-pixel stories are covered too (8 of 9). ErrorBoundary error-state is covered.
- Tools/story-coverage.py: Storybook stories with a reference in the test target, per component, with the missing story names.
- Left out on purpose:
  - Developer-harness stories: AttachmentStatusIcon Interactive; AddNewLines CustomRenderFunction and Linkify CustomTextRender (the story supplies the render callback).
  - Empty captures: TimelineItem MissingItem, TypingBubble *StoppedTyping, three AttachmentDetailPill *Blank.
  - (Emojify's two "tens of thousands of emoji" stress stories are now snapshotted, see Message text.)
- AboutContactModal (18 stories). 16 are ≤1%. Known items: with-about and no-messages ≤1.5% (1.0–1.1% now): the dialog's sub-point height (our rows measure in 1/11pt steps, Chromium's in 1/64px) puts edges on the other side of half-pixel ties.
  - Added along the way: AxoDialog.Header `floating:` (sr-only title, material-subtle Back / Close; the explainer dialogs use it now), rich labels for AxoTextItem / AxoClickableItem, `About`, `SharedGroupNames.runs`.
  - AxoItem.Icon's line box now comes from the inherited text: 14/20 by default, 13/18 inside dialog panels via `\.axoInheritedTextSize`.
- Coverage (Tools/story-coverage.py, 2026-11-05): 1222 of 2043 stories (was 964 at the start of step 4's last batch). By step, roughly: design system 160/189, conversation 554/618, composer and Fun 0/75, right panels 0/127, install / modals / toasts / lightbox 97/387, settings 0/82. Calling, stories and other later-phase components make up most of the rest.
- ProfileNameWarningModal (2, ≤0.29%; DiscListItem for `list-disc`).
- ContactModal (19 of 20, all ≤0.45%; long-label-all-emoji 0.87–1.04% of the portal region: the label's emoji now follow UserText's `verticalAlign: top; marginTop: size/6`, and the rest is quarter-point dialog centring rounding below the label). WithBadges is left out (donor badges); the avatar lightbox and BadgeDialog views are callbacks (step 7).
  - GroupMemberLabel's contact-modal pill: body-1, wraps; a line that can't break is clipped with an ellipsis (WrapOrEllipsis); shrink-to-fit width.
- ContactDetail (16 stories, all ≤0.62%; ContactDetailFields for phones / emails / addresses / nickname / note).
- Step 4 is now complete except the stories left out on purpose (payments, donations, badges, harness and empty stories) and the invited-contacts Timeline story (step 7 dialog). Conversation details panels, media gallery and staged attachments belong to steps 5–6.
### Phase 3 step 5 progress (2026-11-05)
- AttachmentList (5 stories; EmptyList renders nothing), StagedGenericAttachment (3), StagedPlaceholderAttachment (1): all ≤0.6%.
  - Rail tiles are vertical-align middle. Generic tiles are block-level and start their own lines. The rail's top margin collapses out of a header-less story root.
  - Images use the light default blurhash (AttachmentList passes no theme).
  - Test fixtures now decode GIFs (first frame; `fixtureGIFFrame` for the frame a capture caught, since Chromium animates GIFs).
- StagedLinkPreview (11 stories, all ≤0.6%): loading, link-icon placeholder, image / call-link thumbnails, title / description / domain • date, the composition-input card (thumbnail trailing) and the sticker-pack variant.
- RecordingComposer + CompositionRecording (Visible ≤0.01%; Default is an "Activate" harness) and DiscardDraftDialog (≤0.04%). CompositionRecordingDraft's story times out loading in Storybook (it decodes audio on load); retry the capture with a longer wait.
- FunEmoji (All + Inline, ≤0.5%; Fixtures/emoji-all-variants-head.json is iterateAllVariants' order from build/emoji-data.json), FunGifPreview (loading / error ≤0.01%), FunSticker (natural size, reduced-motion still frame; ≤0.8%).
  - FunGif Basic and PreviewSizing show frames of a remote Giphy MP4; they wait for the Swift H.264 decoder (Phase 5).
- Fun base (FunPopoverDialog, FunPanel, FunSubNavListBox, FunScroller with edge hints, FunGridHeader, FunItemButton, FunResultsHeader) and FunPanelEmojis / FunEmojiPicker: both FunEmojiPicker stories ≤0.26%.
  - EmojiData.swift reads upstream's build/emoji-data.json (Tools/gen-emoji-data.sh copies it into Resources).
  - Not ported yet: Fuse.js search (a short-name match stands in) and the skin-tone popovers.
- Legacy Select (2 stories ≤0.25%).
- AxoBaseField: an autoFocus input shows its focused ring in static rendering.
- FunStaticEmoji: Blink rounds the glyph baseline down to the 2x device grid. With a CSS scale (ReactionPicker) the snapping is on the transformed grid, so `snapsBaseline: false` there.
- FunPanelStickers / FunStickerPicker (≤0.47%: natural-size stickers in 80px cells, the scrolling pack sub-nav with 40px fades and 26px covers) and FunPicker with FunTabs (≤0.24%). The GIF panel waits for H.264 (its media are remote Giphy MP4s). The sticker lightbox and time stickers are not ported yet.
- CustomizingPreferredReactionsModal (4 stories ≤0.10%).
- AxoDialog.Body: the thin scrollbar gutter (both edges, 11px) only takes room once the body overflows its max height.
  - The earlier AxoDialog captures had been taken while macOS showed scroll bars always, so they reserved the gutter for content that fits; Chromium follows the system "Show scroll bars" setting. They were re-captured, as were the other stories that disagreed.
  - Known risk: captures depend on that macOS setting. Capture with "Show scroll bars: Automatic", the setting the current references use.
  - Tools/refresh-references.sh copies fresh captures over the references and re-cuts the payment splices.
- CompositionInput (11 stories ≤0.09%).
  - The pill reserves its 1px border; it shows the ultramarine border while it has focus (it focuses itself on open).
  - The scroller is 30–70px (210px large), with the 6px padding inside the scrolling box. On overflow Quill scrolls the caret into view: after text the caret is Inter's content area (line + 18); after an emoji blot it is the 20px box.
  - Emoji are FunStaticEmoji blots (`CSSTextRun.emojiStaticBlot`: the glyph sits where FunStaticEmoji puts it).
  - Live editing uses ComposerTextView: an NSTextView on our own TextKit 2 stack (NSTextView.textContainer is unowned(unsafe)). Return sends; Shift/Option-Return inserts a line break.
  - Not ported yet: the formatting menu, emoji / mention completion, the recovery-key paste warning, the edit banner.
- CompositionArea (13 stories ≤0.40%; QuoteWithPayment is out of scope).
  - Covers every branch in upstream's order: Signal chat (nothing), group ended, MessageRequestActions, SMS-only (and the fetching spinner), profile sharing, GV1 disabled, pending approval, announcements-only, recording / recording draft (render props), and the composer.
  - The composer row: 32px cells with 4px margins (12px at the row ends), CompositionInput with 6px margins, bottom-aligned. Under view-once the Fun button is invisible but keeps its space, and Send replaces "+".
  - Large mode moves the buttons into a control row 12px below. The expand tab shows on hover.
  - New parts: FunPickerButton, AudioCapture, MediaQualitySelector (2 stories 0.00%), ComposerAddMenu, the edit-message buttons, AnnouncementsOnlyGroupBanner.
  - Not ported yet: SelectModeActions, MediaEditor, the poll / share-contact dialogs.
- AnnouncementsOnlyGroupBannerAdminsDialog (≤0.14%), opened from the banner on the modal stack.
- DraftGifMessageSendModal (0.00%, captured while the GIF loads) with CompositionTextArea (CompositionInput `variant: .textArea`: square, transparent, 16px / 36px-end padding, 100–300px) and FunEmojiPickerButton.
  - FunGifPreview sizes through a Layout (the GIF's ratio within the offered width and max height), not a GeometryReader that took the whole max height.
- Step 5 remaining: CompositionRecordingDraft (capture times out), FunGif Basic / PreviewSizing and MediaEditor (Phase 5), and the CompositionInput / Fun picker features listed above.

### Phase 3 step 6 progress (2026-11-05)
- Sources in Components/Conversation/ConversationDetails/; all stories below are captured into .cache/storybook-refs.
- ConversationNotificationsSettings (7 stories ≤0.11%) and WhileMutedSettings (4, ≤0.05%), with MuteExpirationTime (getMutedUntilText: moment `LT` today, else `L, LT`) and NotifyWhileMuted (summary).
  - WhileMutedSettings puts AxoItem.Icon straight in the root (no Leading). AxoBaseItem now treats a bare Icon as its own grid column with no end gap, top-aligned, as Blink does.
- ConversationDetailsHeader (5 stories ≤0.22%; OneOnOne is out of scope, it shows a donor badge). GroupDescription takes the inherited font and colour (`style:`, `color:`).
- ConversationDetailsActions (9 stories) and DeleteMessagesConfirmationDialog (2, 0.00%). The confirmations present on the modal stack; ending a group asks twice.
  - The actions (fixed 2026-11-05): Blink paints a box's background and box-shadows in its border box snapped to whole CSS pixels (`CSSPixelSnap`, used by CSSBoxShadowModifier and AxoList.Body; transformed views stay unsnapped). The elevation-0 ring at the seam now lands on Chromium's row; 152 stories improved, none regressed.
- GroupV2Permissions (6 stories ≤0.09%): AxoSelectItems; restricting labels to admins while non-admins have labels asks first.
- ConversationDetailsMembershipList (8 stories ≤0.07%): AxoContactList gained `titleView:` on Root (the header with its search button) and on Item (the name over the label pill). Seeded member names and avatars are taken from the captures.
- GroupLinkManagement (5 stories ≤0.86%). AxoSwitchItem can make its description a button (`onClickDescription`); AxoBaseItem.Description(interactive:) lets it take clicks.
- PendingInvites (Basic ≤0.05%; WithBadges is out of scope): Requests / Invites tabs and the staged confirmations.
- GroupMembersSearchDialog (8 stories ≤0.47%) with groupByFirstInitial. AxoDialog gained `Search` and Body `forceMaxHeight`.
  - Ranking is `filterAndSortConversations` (Fuse.js scores plus recency) and is passed in as `search`. The default is a substring match in title order; a Swift Fuse port is still to do (the emoji picker search needs it too).
  - The test injects the captured order, since recency comes from random activeAt values. GroupMembersSearchDialogFixtures.swift is generated from the captures' DOM.
- GroupTitleInput / GroupDescriptionInput (4 stories ≤0.01%).
- The avatar editors:
  - BetterAvatarBubble (3) and BetterAvatar (2), AvatarColorPicker (2), AvatarModalButtons (2), AvatarUploadButton (1).
  - AvatarPreview (8; it replaces the earlier partial port in DisappearingTimerSelect.swift and gains `margins:` and `autoFocus:`).
  - AvatarIconEditor (2), AvatarTextEditor (3), AvatarEditor (4).
  - All are ≤0.16%.
  - The preset avatar icons (images/avatars) are now vector SignalIcons. gen-icons has an avatar pass (fills inherited from <g>, circles, strokes, the full-viewBox clip), and SignalIconPath gained strokes.
  - Exclusion: BetterAvatar Text. In Storybook avatarDataToBytes loads Inter from an asset:// URL that never resolves, so the capture is the spinner.
  - AvatarTextEditor fits its font before Inter loads in Storybook, so the tests inject the captured sizes; the default fits in Inter.
  - A picked photo is handed over as a file URL; decoding belongs to the media service.
  - Tools/capture-storybook.mjs: CAPTURE_SETTLE_MS extends the wait for stories that render asynchronously.
- EditConversationAttributesModal (5 stories ≤0.11%). With a request active the inputs are disabled, so the avatar takes the initial focus.
- AddGroupMembersModal (5 stories ≤0.68%), with ChooseGroupMembersModal (the legacy 342px × 60vh modal), ConfirmAdditionsModal and the group-size error dialogs (2 stories ≤0.55%). Finding people by phone number or username is not ported yet.
  - Tools/capture-storybook.mjs now treats ModalHost's width container as a portal. ModalHost-only stories, which carry no role=dialog, used to fail as "empty story".
  - CAPTURE_DEBUG=1 prints page errors, console errors and the DOM of empty stories.
- GroupMemberLabelEditor (9 stories ≤0.14%; WithBadge is out of scope): the label input with the emoji button, the preview message, the members' labels, and the permissions alert.
- ConversationDetails (17 stories ≤0.46%, plus SignalConversation with its "Donate to Signal" row spliced out) and ConversationDetailsGroups. ConversationDetailsFixtures.swift is generated from the captures' DOM; each story re-seeds its members.
  - AxoContainer.Root now wraps its content in one VStack. Its padding had been applied to each child of a multi-view body (each section got 8px above and 16px below).
  - Not ported yet: WithCallHistoryGroup (CallHistoryGroupPanelSection needs the call-history formatting) and the in-another-call tooltip.
- Media gallery parts (Components/Conversation/MediaGallery/), all ≤0.48%:
  - EmptyState (5 stories).
  - MediaGalleryListItem (ListItem) with DocumentListItem, AudioListItem, LinkPreviewItem and GalleryContactListItem (Multiple each). The rows are generated from the captures' DOM (*Fixtures.swift), since mediaGalleryMocks are random.
  - MediaGridItem (12): alone a tile is as wide as its image; a video's url is its screenshot's.
- AttachmentSection (4 stories ≤0.15%) and MediaGallery (5, ≤0.05%), with MediaGalleryPanelHeader, MediaGalleryGrouping (groupMediaItemsByDate) and ConversationPanel (the panel frame with the back button).
  - The capture tool records an img's src: blurhash previews are data:image/bmp URLs of the decoded pixels, which the tests decode with ImageBMP (a test-only dependency).
- ChatColorPicker (2 stories ≤0.05%) with SampleMessageBubbles / SampleMessage (text over its metadata line; outgoing gradients span the sample card) and CustomChatColor (`270 − angle` gradients).
  - The first preset takes the initial focus (ultramarine border). The card's 0.5px border is drawn one CSS pixel wide, as Chromium does.
- Pinned messages: PinMessageDialog (1 story; the duration step, then the replace-oldest and pin-limit dialogs) and PinnedMessagesBar (2 stories ≤0.20%; tabs strip, preview priority, 1px top border).
- Stickers: StickerManager (5 stories ≤0.05%; the panel autofocuses and shows its focus ring, heading/trailing margins collapse out of the panel) and StickerPreviewModal (7 stories ≤0.70%; floating header, StackedButton row, 5-column grid with placeholders, error / initial-download states). Not ported: drag reordering of installed packs.
- PixelImage now downsamples as Chromium does: mip level floor(log2(scale)), sampled bilinearly (Skia medium quality); the old area filter left 1.5-2% on 4× downscaled stickers. Chromium paints the preview grid's 62.4px cells as whole 62px squares (rounded up), which the grid copies. The full suite still passes (327 tests).
- CustomColorEditor (2 stories ≤0.13%) with GradientDial (knobs where the angle's line meets the inset-8 edge, the rotated 6px line, drag to rotate) and CustomColorEditorDialog (3 stories ≤0.27%), plus AxoDialog.Tabs / TabList / Tab / TabContent (no height animation or cross-fade yet) and `calculateLightness`.
- AxoBaseDialog.Host now rounds the centred dialog origin to whole points, as Chromium paints it (199.5 → 200, 252.55 → 253). 43 dialog stories improved, 12 moved up by at most 0.35% and still pass; full suite 329/329.
- Next: the ContactDetails / GroupInvites panel wiring and the call-history section. Re-capture other stories that failed as "empty story", now that ModalHost portals are detected.

### Phase 3 step 7 progress (2026-11-05)

- Captures: 137 step 7 stories (install screen, modals, safety numbers, forward message, …) plus the 17 Lightbox / AvatarLightbox stories, now that Tools/capture-storybook.mjs treats `#lightbox` as a portal. Still uncaptured: DialogUpdate UnsupportedOS wide/narrow (render nothing in Storybook).
- Install screen (Components/InstallScreen): InstallScreenSignalLogo, InstallScreenLinkInProgressStep (1 story), InstallScreenErrorStep (3), InstallScreenQrCodeNotScannedStep (9; loading, failed, loaded, confirm data deletion, the Simulated* stories as captured while loading) and InstallScreenUpdateDialog (13, plus the step's expired state). All ≤0.42%. Not ported: the *StandaloneIsSupported stories (linked-only) and InstallScreenBackupImportStep (no backups).
- QRCodeGenerator: a port of qrcode-generator 2.0.4 (byte mode, auto type, lost-point mask choice), bit-exact with the JS library on 20 vectors (Tests/SignalUITests/Fixtures/qrcode-generator-vectors.json). BrandedQRCode draws upstream's rounded modules, the cleared centre ring and the logo.
- `viewportOrigin` / `viewportSize` environment values place CSS `position: absolute` / portal content against the window when a view does not fill it (the stories put the screen at (16, 16)).
- AxoButton / AxoAlertDialog.Action take `labelRuns` (styled label parts); AxoAlertDialog.Description takes runs with link taps.
- Full suite 334/334, lint ok.
- Lightbox (9 of 14 stories ≤0.04%: images, captions, the thumbnail strip, unsupported / missing placeholders, custom children; always force-dark, Close focused) and AvatarLightbox (3, ≤0.03%). The 5 video stories wait on Phase 5. Chromium paints the lightbox `<img>` into its fitted rect rounded outward to device pixels: `PixelImage(snapsOutward:)`.
- PixelImage, AvatarPreview `initialsFontSize`, Tools/gen-icons.mjs now also emits images/image, file and alert-outline.
- ProgressModal (2; the panel itself has the focus ring when nothing inside is focusable: `AxoDialog.Content(focused:)`), ConfirmDiscardDialog (1), DebugLogErrorModal (1), DisappearingTimeDialog (5), GroupV2JoinDialog (6; the avatar GIF is captured at frame 19), DeleteMessagesModal (9), NewlyCreatedGroupInvitedContactsDialog (3). All ≤0.20%. Donation stories (ConfirmDiscardDialog DonateFlow, DebugLogErrorModal Donations) omitted.
- AxoDialog.Body no longer adds a scrollbar gutter when it scrolls (the captures of scrolling bodies keep the plain padding).
- Full suite 341/341, lint ok.
- Fuse (Sources/SignalUI/Search/Fuse.swift): a port of Fuse.js 7.1.0 — Bitap with JS int32 arithmetic on UTF-16, the extended-search operators and `|`, field-length norm, raw key weights (as Fuse.js's index uses them). Identical to Fuse.js on 41 queries / 170 ranked results (Tests/SignalUITests/Fixtures/fuse-vectors.json, scores within 1e-12).
- ConversationSearch: `filterAndSortConversations` (upstream's 13 keys, threshold 0.2, distance 200, `!command:` filters, recency / archived / left scoring, letter-first `localeCompare`). It now backs ForwardMessagesModal, AddGroupMembersModal and GroupMembersSearchDialog. The phone-number OR clause uses a small E.164 normaliser in place of libphonenumber.
- ForwardMessagesModal (7 stories ≤0.28%): search, the 52px checkbox list (5 at most; announcement-only groups refused with the GroupV2--cannot-send alert), the footer's chosen names and next / send. The editor step reuses CompositionTextArea; its staged link preview and attachments are not shown yet. ModalPage gained `contentTakesFocus()`.
- Full suite 344/344, lint ok.
- SafetyNumberViewer (12 stories ≤0.11%; the stories' random QR data and digits are rebuilt from each capture's recorded SVG, Tests/SignalUITests/Components/SafetyNumberViewerFixtures.swift) with QrCode (level L, qrcode-generator's createSvgTag modules) and the key-transparency button and popups. SafetyNumberChangeDialog (7 stories ≤0.56%: start-in-review, explicit review for more than five, post-review, story sections with hover menus). MultipleContactsAllWithBadges omitted (donor badges).
- About (1 story; one Swift `About` type serves both upstream `About`s: the window and the conversation about line), Toast (2), DebugLogWindow (1). All ≤0.22%. The ToastManager story's capture is only its harness line (the manager is fixed-positioned outside the clip); the ToastManager's toast types are not ported yet.
- Full suite 349/349, lint ok.
- ToastManager: `ToastType` (89 types with their parameters) and `renderToast` (texts, short / default timeouts, actions: undo archive, show in folder, submit log, retry survey), at the bottom of the window. A test checks every message key it uses exists. Donation and backup toasts omitted. Megaphones in the container are not ported yet.
- Next: step 8 (settings).

### Phase 3 step 8 progress (2026-11-05)

- Captured all 82 Preferences stories. Every capture's sidebar has "Donate to Signal" and "Backups" rows; Tools/splice-reference.py gained a column mode (`<left> <right>`) that cuts them from the sidebar column only. Donation and backup pages / stories are not ported.
- Preferences shell (Components/Preferences/Preferences.swift): NavSidebar with the profile chip (avatar, name, number, username, QR button) and PreferencesButton rows (their `my-0.5` margins collapse: 2px between rows, 4px after the chip, 8px around the divider); `SettingsPage`; the page beside it. PreferencesList, PreferencesContent (the legacy 52px-title frame), PreferencesItemWithAction. Tools/splice-preferences.py finds the Donate / Backups rows in each capture's DOM and cuts each with one (collapsed) margin.
- Pages: Appearance, Calls (with CallingDeviceSelectionItems and the audio device model), Data usage, Notifications (+ reset confirmation), Privacy (+ custom timer dialog, screen security and stories-off confirmations), Chats (with FunSkinTonesList), Account (linked device; its first control has the initial focus ring, as upstream focuses the pane's first control). 11 stories, all ≤0.11% except Account (≤0.90%). AxoSwitchItem gained `labelSuffix` and `descriptionRuns`.
- General (linked-device rows; the primary-device PIN / registration lock / delete-account rows are out of scope, so the *-when-primary stories are not ported), PNP (legacy SettingsRow / SettingsRadio / back button: PreferencesUtil.swift), While muted, the six privacy-blocked variants, and PreferencesBlocked (8 stories; fixtures read off the captures). All ≤0.11%.
- Dialogs done: LinkedDevicesOnboardingDialog, PreferencesLanguageDialog (default + search), PreferencesBlockChooserDialog (presented by PreferencesBlocked).  PreferencesSelectChatsDialog (5 stories). Pages: chat-folders, edit-chat-folder (ChatFolderPreset/ChatFolderParams, SettingsControl, Preferences__actions footer, inset focus ring). ConversationList gained GenericCheckbox and EmptyResults rows (ConversationListRowView). ContactPill max-width is now relative to the pills box (CSSFlex `maxMainInset`). Suite: 366 tests pass, lint ok.
- Also done: Profile (ProfileEditor main page, 7 ProfileEditor stories + the `preferences` story; the avatar page is AvatarEditor, the name/about/username/link pages come from `renderSubpage`), Account keys + e164-less Account (SignalAccountKeys ×2, SignalAccountKeysButton, OSAuthErrorDialog, SignalLoginIllustration drawn from images/signal-login.svg). Item focus rings now go on the item root (`axoItemFocusVisible`). `axoViewport()` at the window root: `viewportPortal` dialogs measure their place in it, so a dialog opened from a settings page covers the window. Suite: 371 tests pass, lint ok.
- Also done: notification profiles (the three-profile Notifications stories render the plain page; NotificationProfilesOnboardingDialog + ProfileAvatar), Internal (backup and donation-receipt sections left out and spliced from the reference; InternalFlowRow models the 66%/33% vertical-align-middle cells), nav-tabs-collapsed ×3, showing-update-dialog. SettingsRow counts its 1px border in its height (as upstream); CSSText gained `text-wrap: pretty`; Input gained an `inputTextStyle` override. Step 8 stories are all covered except donations, backups and *-when-primary.
- Phase 3 inventory (2026-11-05): 479 index stories had never been captured. Captured the 117 in Phase 3 scope (calling, stories, media editor, plaintext export and standalone registration stay with their phases); 14 of them are blank or time out (audio). Ten new stories of already-ported parts now pass (UniversalTimerNotification ×5, InContactsIcon, OfficialChatInlineBadge, QrCode, BrandedQRCode, DisappearingTimerSelect ×2, CountryCodeSelect, ListTile, CollidingAvatars, PlaybackButton with its draft/mini variants).
- New components passing (2026-11-05): ErrorModal, TerminateGroupFailedModal, DeleteAttachmentConfirmationDialog, TapToViewNotAvailableModal ×2, BackfillFailureModal ×2, NotePreviewModal, CriticalIdlePrimaryDeviceModal, KeyTransparencyErrorDialog, KeyTransparencyOnboardingDialog (illustrations drawn from the SVGs), WhatsNewModal, SignalConnectionsModal, SafetyNumberModal ×2, MuteUntilDialog (with DatePicker / TimePicker). CSSText `pretty` now follows Blink's score line breaker (≤4 lines: least squared slack, two words on the last line); AxoDialog.BodyTitle; SafetyNumberViewer links are underlined (a[href]). UsernameOnboardingModal, SafetyTipsModal, EditNicknameAndNoteModal, AddUserToAnotherGroupModal, I18n ×6, Slider ×2, IdenticonSVG ×3, GroupMemberLabelInfoModal ×4, GroupV1MigrationDialog ×6, NotificationProfilesMenu ×6 (AxoDropdownMenu.CustomItem / ContentSeparator), ShareContactDialog ×7 (all four steps ported), UsernameEditor ×8, UsernameLinkEditor ×2 (colour picker included) also pass (gen-icons now builds multi-colour illustrations: rect/circle/rotate/fill-opacity/style classes). DeleteAccountConfirmDialog is primary-only and MaybeTransferModal / DeleteDataAndRelinkConfirmationDialog offer link-and-sync history transfer (no history import on link): out of scope.
- Also passing (2026-11-05): EditHistoryMessagesModal (MessageMetadata draws the empty status-icon box for an outgoing message without a status; `messagePaddingInline`), PollCreateModal, AnimatedEmojiGalore (a still frame: `initiallyAtRest` and injectable particles), ChatsTab (the no-conversation splash, now the app's Chats tab), Conversation/GroupNotification story (SystemMessage `contentsIsParagraph`: an inline-block <p> too wide for the icon's line drops below it; empty <p> keeps its 4px). Capture tool: `CAPTURE_REMOUNT=1` remounts a story once fonts have loaded (Message's metadata spacer keeps the widest width it measured, so a cold page measured the fallback font); the PNG clip and JSON size are clamped to the page. EntryPoint is out of scope: upstream shows it only when standalone registration is enabled, otherwise it opens the installer. SignalUI: 398/398 tests pass.
- Earlier-captured stories, now passing (2026-11-05): AxoDialog ×7 (floating header, full-width actions, tabs, long content, three examples), AxoTooltip ×5 (popper `hideWhenDetached` with `axoPopperClip()` on scroll viewports, inset by the collision padding), AxoAvatar ×4 (Image `blur`, `Preset`), AxoStackedButton tooltip, AxoSelect Open (the native popover is replaced by Radix item-aligned placement on the popper layer, keyboard focus ring), AxoDropdownMenu stress test (`runs(_:)` rich item labels), AxoMenuBuilder (new), AriaLabelled + AriaClickable (new), Avatar ×7, contact pills ×4 (random data read per theme from the DOM: Tests/.../Support/StoryDOM.swift), Linkify / AddNewLines custom renderers, ConversationDetails with call history (CallHistoryGroupPanelSection), ToastManager BasicUsage (megaphone slot, `containerWidth`). Popper origins are rounded to device pixels (floating-ui roundByDPR; ties to even, since SwiftUI hands back pixel-snapped anchors). Capture tool: fixed-position descendants join the clip union; the clip is clamped to the page. SignalUI: 416/416 tests pass.
- Closing the gaps (2026-11-05): AxoSymbol All (621 cards; tall captures are now taken in 4000px bands and stitched, and tall snapshots render in bands when one image comes back unreadable), AxoButton WidthsTest (all six layout contexts via CSSFlex, 0.02%), the Timeline invited-contacts story (CAPTURE_SETTLE_MS=3000: the gutter variable had not been measured yet), CompositionRecording and MiniPlayer (new; CAPTURE_CLICK=Activate presses the harness button), CompositionRecordingDraft (new; the network-idle wait no longer times out on audio), AttachmentStatusIcon Interactive, BetterAvatar Text (the tool rewrites asset:/// font URLs; CAPTURE_REMOUNT preloads Inter), and the five Lightbox video stories (CAPTURE_PAUSE_MEDIA: first frame; the frame comes from Tests/.../Fixtures/pixabay-Soap-Bubble-7141.frame0.png, extracted with ffmpeg until Phase 5 decodes H.264; LightboxVideoControls reproduces Chromium's paused controls panel at the element's bottom). CSSText fixes found on the way: typesetters are unbounded (CoreText's default drops letter-spacing past ~12k UTF-16 units and returns empty lines beyond its limit), and an Emojify run boxes at most 5000 emoji (MAX_EMOJI_TO_MATCH). SignalUI: 429/429.
- Accepted known items (user decision, 2026-11-05), held by their existing tolerances: MessageBody zalgo-text ≤6% (3.9–4.6%; combining-mark stacking is HarfBuzz mark/mkmk positioning in Chromium, CoreText's here), ContactModal long-label-all-emoji ≤3% (1.04% light portal), AboutContactModal no-messages and with-about ≤1.5% (1.0–1.1% portal; half-pixel ties in fractionally centred dialogs). Every other story is ≤1% with no tolerance. SignalUI: 430/430.
- Still not snapshotted, with reasons: FunGif Basic / PreviewSizing (their media is a remote third-party Giphy clip that upstream does not ship, so no frame of it is vendored). Out of scope as before: donor badges, payments, backups, donations, standalone registration, primary-only and Windows stories. Calling (Phase 6), stories, media editor and plaintext export (Phases 5/7) are later phases.
