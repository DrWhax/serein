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

## Status (2026-11-05): Phase 4 step 3 (attachments) done

- **Crypto** (`SignalCore/Attachments/AttachmentCipher.swift`): v2 blobs as upstream — zero padding to `logPadSize`, AES-256-CBC, HMAC-SHA256, SHA-256 digest; integrity by digest or plaintext hash; libsignal incremental MAC (chunk size inferred as upstream, MP4 only); `decryptAndReencryptLocally` (version 2 local files under a fresh local key).
- **Upload** (`AttachmentUploader`): upload form from libsignal's typed `getUploadForm` (Attachments/GetUploadForm), then TUS creation-with-upload on CDN3 (resumed with HEAD/PATCH and the Fibonacci backoff) or the resumable PUT on CDN2. Pointers are reused for 3 days.
- **At rest** (`AttachmentStore`): `<2 hex>/<64 hex>` encrypted files; stored paths cannot escape the root; "Save as" exports set the quarantine properties (through `URLResourceValues`, no xattr C call).
- **Downloads** (`AttachmentDownloadManager`): upstream's `attachment_downloads` table, visible messages first (oldest first) then newest first, 6 at once, retries 30 s ×10 up to 6 h over 5 attempts, permanent errors for 403/404/too big/integrity; results land in `message_attachments` rows (`MessageAttachment` ↔ AttachmentPointer).
- **Policy**: `auto-download-attachment` (photos/videos/audio/documents), small voice notes always, `global.attachments.maxReceiveBytes` / `maxBytes` / `maxAutoDownloadSizeBytes` via the new `RemoteConfig` (GET /v2/config with ETag, upstream's `remoteConfig` item shape).
- **Media service** (`Packages/SignalMediaService`): `MediaXPCInterface` (types + `MediaProcessing`, the only part SignalCore links; lint-enforced) and `SignalMediaDecoder` over SignalCodecs: 150 px cover-cropped PNG thumbnails, 4×3 blurhash from a 200 px fit, and `scaleImageToLevel` (levels 1–3 from `desktop.mediaQuality.levels` by our calling code; ladder 3072…768, then 512; JPEG). The XPC executable itself is still to come; tests run the decoder in process.
- **Tests**: AttachmentCipherTests (padding buckets, MAC/digest/plaintext-hash failures, incremental MAC, local re-encryption, path containment, quarantine, policy, backoff, quality levels) and AttachmentFlowTests against the mock server: an image sent to alice and decrypted by an independent Node implementation of upstream's format, and an incoming attachment downloaded, verified and re-encrypted at rest. SignalCore: 66 tests.

## Status (2026-11-05): Phase 4 step 1 (Groups v2) done

- **Credentials** (`Groups/GroupCredentials.swift`): daily AuthCredentialWithPni from `/v1/certificate/auth/group` (today … +6 days, upstream's `groupCredentials` item), presented per request as Basic `<publicParams hex>:<presentation hex>`.
- **State** (`GroupModel.swift`): GroupKeys (master key → secret/public params, group id), `GroupV2State` in upstream's conversation attribute names (membersV2, pendingMembersV2, pendingAdminApprovalV2, bannedMembersV2, accessControl, revision, …), decryption of Group protos (members, invites, requests, bans, title/description/timer blobs, labels).
- **Changes** (`GroupChange.swift`): GroupChange.Actions decryption (ciphertexts or credential presentations), `applyGroupChange`, and `extractDiffs` → `group-v2-change` / `timer-notification` messages in the GroupV2ChangeDetail shape SignalUI's GroupChangeRenderer reads.
- **API** (`GroupsAPI.swift`): get, joined_at_version, paginated logs (206 + `Content-Range: versions a-b/c`), create, modify (with `inviteLinkPassword`), join info, avatar download (CDN 0) and upload (avatar form + S3 multipart).
- **Updating** (`GroupsService.swift`): per-group serialised `update` from a message's groupV2 context (single signed change for the next revision, else logs from our revision or joined-at version; 403 → removed), profile keys to contacts, avatar fetched and stored encrypted, endorsements saved.
- **Modifying** (`GroupsService+Modify.swift`, `GroupActions.swift`): every upstream builder (add/invite, attributes, timer, links, access, announcements-only, roles, labels, approve/deny, ban/unban, remove/leave, accept/decline/revoke invites, profile key, terminate), PATCH with refresh + 409 retry, the signed change applied and sent as a group update to everyone concerned plus a transcript; `create` (us as admin, members by presentation or invited), join via link / request to join (`GroupLinks.swift`, signal.group and sgnl:// links).
- **Sending** (`Messaging/GroupSender.swift`): sender key distribution to devices without our key (`senderKeyInfo`), groupEncrypt + `sealedSenderMultiRecipientEncrypt` sent via MessagesAnonymous/SendMultiRecipientMessage with a GroupSendFullToken from the stored endorsements (`groupSendCombinedEndorsement` / `groupSendMemberEndorsement`, `buildToken`), mismatched-device retry, 1:1 fallback; `Messenger.sendGroupMessage`.
- **Not ported**: Groups v1 → v2 migration (no v1 groups remain).
- **Tests** (GroupTests): keys/blobs, credential ranges, log range header, apply+diff, every builder round-tripped through decrypt+apply, avatar blob and multipart, link parsing; against the mock server: receiving a group and a signed timer change (+ endorsements), a sender-key send to two members (SealedSender/SenderKey on arrival), create + rename seen by alice and the server, join via link, request to join. SignalCore: 79 tests.

## Status (2026-11-05): Phase 4 step 2 (storage service) done

- **Service** (`SignalCore/StorageService/StorageService.swift`, replaces the read-only `StorageServiceReader`): upstream's `sync` / `processManifest` / `processRemoteRecords` / `generateManifest` / `upload`. Sync fetches the manifest (204 = same, 404 = none), fetches only remote keys we do not hold, merges them in upstream's order (plain records → split-PNI contacts → chat folders and notification profiles → account), each merge in its own savepoint (failures become `storage-service-error-records`), then forgets local storageIDs the manifest dropped (tombstones are deleted) and creates My Story and the All Chats folder when missing. Upload regenerates every record; records that need sync or have no storageID get a fresh random 16-byte storageID (old key deleted); unknown and failed records pass through by storageID; expired tombstones are deleted; the write is checked against the previous manifest as upstream does (inserts = local − remote, deletes ⊇ remote − local), sent as one `WriteOperation` to `PUT /v1/storage/`, and a 409 means sync and regenerate (up to 3 times). After a write, a SyncMessage.FetchLatest(STORAGE_MANIFEST) is queued for the phone. Syncs and uploads run one at a time (`storageJobQueue`); uploads wait for the first sync (`runStorageServiceUploadJobAfterEnabled`); queued uploads are coalesced; `fromSync` uploads are limited to 3 per 5 minutes; undecryptable data asks the primary for keys, and a Keys sync starts a new sync.
- **Record ops** (`StorageRecords+Conversations.swift`, `StorageRecords+Tables.swift`): to-/merge- for ContactRecord (first-sync rules for profile key, names and identity key; conflicts set needs-sync; blocked/whitelisted message-request state; hidden, unregistered, mute, avatar colour), GroupV2Record (then a group refresh), AccountRecord (every setting item, pins un-archive, username link, notification-profile override, release-notes chat; payments, donor and backup fields are kept as items only so write-back preserves them), StoryDistributionListRecord, InstalledStickerPackRecord (installed/uninstalled tables; downloads queued as `sticker pack download` jobs for step 4), FavoriteStickerRecord, CallLinkRecord (call links, defunct links, pending `call link refresh` jobs for Phase 6; room id = ringrtc HKDF), ChatFolderRecord (All Chats upsert, deletion timestamps), NotificationProfile (schedule days JSON, sync-disabled rule). Unknown proto fields are stored per record and re-attached on regeneration. GROUPV1 and HIDDEN_STICKER_PACK records are passed through unchanged.
- **Local state** (`StorageLocal.swift`): upstream's blocked lists (`{serviceId|e164|groupId, blockedAt}`; the Blocked sync now writes this format), MuteExpiration and OptionalBool mappings, Recipient ↔ conversation id, ACI/PNI/e164 contact matching. Binary service ids are written unless the remote config turns `desktop.binaryServiceId.prod` off (the mock server's protos no longer have the string fields).
- **Write-back** (`StorageWriteBack.swift`): `conversationChanged`, `accountChanged`, `recordChanged(.chatFolder/…)` mark the record and queue an upload in the caller's transaction (`captureChange`). Hooked now: profile sharing enabled on send, group created/joined. The step 6 features (archive, mute, pin, block, nicknames, …) will call these.
- **Simplified vs upstream**: contact merging is ACI → PNI → e164 lookup with PNI attach, not the full `maybeMergeContacts` (no merging of two existing conversations); `validateConversation` is not ported (only the unregistered-and-stale drop); no Signal release-notes conversation yet (its AccountRecord state lives in items).
- **Tests** (`StorageWriteTests`, plus `StorageReadTests` updated for upstream semantics: pins un-archive, the fetched profile overrides seeded names): every record type merged from the phone; local changes uploaded and decrypted by the mock phone's own storage code, with every phone-written field (identity, payments, donor, backup tier, username link, pins, unknown item type) preserved and no orphaned keys; a phone write racing ours → 409 → merge → retry with both changes kept; unknown proto fields survive merge + regeneration; item/manifest crypto incl. tamper, wrong-derivation and version-mismatch rejection. `swift test`: 84 tests in 19 suites pass; lint ok.

## Status (2026-11-05): Phase 4 step 4 (stickers) done in SignalCore

- **Packs** (`SignalCore/Stickers/StickerService.swift`): manifest `/stickers/<id>/manifest.proto` and images `/stickers/<id>/full/<n>` from CDN 0, decrypted with `deriveStickerPackKey` (HKDF "Sticker Pack", 64 bytes) + `decryptAttachmentV1` (new `AttachmentCipher.decryptV1`, MAC checked first); manifest parsed as upstream (≤ 1024 stickers, cover fallback and emoji, cover-only stickers); every image is sniffed and must be read by the sandboxed media service (dimensions come from there) before it is stored encrypted at rest; a bad sticker is skipped, all bad = `error`, more than 3 attempts = `error`; packs download one at a time. Install / uninstall / favourite follow upstream's SQL (positions, `storageNeedsSync`, uninstall tombstones, `maybeDeletePack` removes unreferenced packs and their files); `ui` changes send SyncMessage.StickerPackOperation and queue a storage upload; StickerPackOperation from the phone installs (downloading first) or removes; storage-service sticker and favourite records queue downloads that this service now runs; the 11 blessed packs (`ensureBlessedPacks`).
- **Messages** (`Stickers/MessageStore+Stickers.swift`, MessageReceiver, Messenger): incoming and synced-sent DataMessage.sticker are validated (16-byte pack id, 32-byte key, image pointer), stored as the message's `sticker` attribute plus a `sticker` attachment, the pack becomes `known` with a reference; when the pack is local the image is copied from it (`resolveReferences`), otherwise the pointer is downloaded. `Messenger.sendSticker` (contact or group) sends the local image untranscoded, WebP through libsignal's **WebpSanitizer**, dimensions and blurhash from the media service, with recents (`lastUsed`) updated.
- **libsignal**: `Tools/vendor-patches/libsignal-media.patch` builds the `signal-media` feature, declares `signal_webp_sanitizer_sanitize` (missing from the generated header) and compiles the Swift WebP API; the Mp4 wrapper (written for the older handle API) stays fenced off until Phase 5 updates it.
- **Panel data** (`Stickers/StickerManagerState.swift`): upstream's selectors (installed by position, received / blessed / known newest first, 24 recents, installed favourites) for the Phase 3 StickerManager view. Not yet connected: the app target does not link SignalCore at all yet (it still runs on demo data); hooking views to live data is the app integration step.
- **Tests** (`StickerTests`): RFC 5869 check of the pack key against CryptoKit HMAC, V1 MAC rejection, manifest rules; against the mock CDN with packs encrypted by the harness (Node crypto): WebP, PNG, APNG and animated WebP installed and read back byte-exact with dimensions, install/remove syncs to the phone, uninstall tombstone + pack deletion, bad MAC and non-image stickers skipped, missing pack → `error`, path-like pack ids refused, incoming sticker downloaded vs. copied from a local pack, sent sticker decrypted by the harness + transcript, phone install/remove followed, favourites. `swift test`: 91 tests in 21 suites pass (twice); lint ok.

## Status (2026-11-05): Phase 4 step 5 (link previews) done

- **Parser** (`SignalCodecs/Sources/HTMLMeta`, new): the untrusted page HTML is read only by the sandboxed media service (`MediaProcessing.linkPreviewHTML`, re-validated in the main process). A restricted tokenizer for exactly what upstream's DOMParser + querySelector calls read: `<title>` (first, whitespace-collapsed), `<meta>`, `<link>`; comments, declarations and raw-text elements (script, style, textarea, …) skipped; first duplicate attribute wins; HTML 4 named + numeric references; charset as `parseHtmlBytes` (UTF-8 BOM, HTTP charset, `<meta http-equiv>` then `<meta charset>`; UTF-8/16, Latin-1/windows-1252). No Foundation, cursors only, ≤ 20 000 tags, ≤ 64 attributes, ≤ 4096-character results. Lint: SignalCore may not import it.
- **Fetch** (`SignalCore/LinkPreviews/LinkPreviewFetch.swift`): `linkPreviewFetch` ported over an injectable transport: manual redirects (≤ 20 requests, loops, every hop https/not excluded/not sneaky), status, `Content-Disposition` inline, `Content-Length` ≥ 8, `Content-Type` (HTML, or an allowed image type → titled by the last path component), ≤ 1000 KiB of HTML, ≤ 1 MiB images, `WhatsApp/2` user agent, OpenGraph image resolved against the final URL, `Date.parse`-style dates within (0, 3000). Images: GIFs kept (but must read as an image), others re-encoded by the media service (`scaleImageToLevel`). The URLSession transport is ephemeral, cookie- and cache-less, and **tunnels through Signal's content proxy** (`contentproxy.signal.org:443`, CONNECT; `ContentProxy.direct` gives upstream Desktop's direct fetch).
- **Service** (`LinkPreviewService.swift`): `getPreview` with the 60 s timeout; sticker pack links (local pack or manifest + cover fetched without storing, `StickerService.preview`), group invite links (`preJoinInfo`, decrypted avatar), call links (default title until calling), pages. The sent strings come from `LinkPreviewStrings` (localized by the app).
- **Messages**: `Messenger.sendMessage`/`sendGroupMessage(preview:)` keep the image at rest (not transcoded again) and send DataMessage.preview with its uploaded pointer; received and synced previews are kept only when previewable and their URL is in the body (`getValidLinkPreviews`), with `domain`/`isStickerPack`/`isCallLink`, images queued per the auto-download policy.
- **Shared rules** (`Packages/SignalText`, new): Phase 3's linkify-it port and sneaky-link rules moved out of SignalUI so SignalCore uses the same code; `findLinks` (with caret), `shouldPreviewHref`, excluded domains, `isValidLinkPreview`, signal.art / signal.group / signal.link URL patterns.
- **Found and fixed on the way**: attachments were written with `.completeFileProtection` (class A), which refuses writes while the Mac is locked, so attachments received with the screen locked could not be stored; now class C (until first unlock), as Signal-iOS, the blobs being encrypted under their own keys anyway. The test helpers leaked ~2.6 GB of databases and attachment folders into $TMPDIR; they now clean up.
- **Tests**: HTMLMetaTests (upstream's parser cases: kitchen sink, image source order, titles/descriptions, charsets incl. BOM/HTTP/http-equiv/meta charset, hostile input); LinkPreviewRuleTests; LinkPreviewFetchTests (upstream's fetch cases against a fake transport: headers, every redirect status, loops/insecure/excluded/too many, 1000 KiB cutoff, direct images, GIF passthrough, fake/oversized/non-image images); LinkPreviewFlowTests (the real URLSession transport through the harness's CONNECT proxy to an HTTPS site under the mock CA, redirect + image, user agent; send with preview, image decrypted by the harness; received previews validated; sticker-pack, group-link and call-link previews). `swift test`: SignalCore 98 tests in 24 suites; SignalMediaService, SignalCodecs (HTMLMeta, CodecCore, ImagePNG) and SignalUI link tests pass; the app builds; lint ok.

## Status (2026-11-05): Phase 4 step 6 done in SignalCore (Phase 4 complete at the SignalCore level)

- **Message modifiers** (`Messaging/MessageModifiers.swift`, `Messenger+Modifiers.swift`, `DeleteForMe.swift`): targets found by author + any sent timestamp (edits included); modifiers arriving before their target are persisted (48 h, ≤ 500) and applied when it is stored. Reactions (one per sender, replace/remove, sync keeps the newest, only senders of the conversation, outgoing targets only once sent to them, not on deleted or view-once messages, `reactions` table with unread flags); delete for everyone (author only, `global.normalDeleteMaxAgeInSeconds` + a grace day, not in Note to Self) and admin delete (group admins, `global.adminDeleteMaxAgeInSeconds`), erasing body/attachments/previews/quote/sticker/poll/history/reactions/pins; edits (author only, ≤ 2 days, newest wins, edit history, previews of the edit, sync edits); polls (2–10 options, one vote per voter by vote count, single-choice and index checks, author-only end); pins (limit `global.pinnedMessageLimit` = 3, oldest dropped, duration or forever, attribute-permission check in groups, pinned-message notification, expiry cleanup); view-once (erase on open, viewOnceOpen sync both ways, viewed receipt); delete-for-me sync both ways (messages, conversations up to the named newest messages, local-only conversations, single attachments). Outgoing: `react`, `deleteForEveryone`, `deleteForMe`, `edit`, `createPoll`, `vote`, `endPoll`, `pin`/`unpin`, `openViewOnce` — applied locally, sent by a `ModifierSend` conversation job with the transcript to our devices. Blocked senders' messages are dropped.
- **Conversation state** (`Messaging/ConversationState.swift`): disappearing messages (versioned timer updates and timer notifications, message timers starting at send or when read, `deleteExpiredMessages`, the universal timer on a new chat, group timers via group changes); message requests (`isConversationAccepted`, incl. `addedBy` for groups now recorded by the groups service; media in unaccepted chats is not auto-downloaded; accept/delete/block/block-and-delete/spam/block-and-spam both ways, accept sends our profile key); blocking (lists, Blocked sync with the whole list, profile sharing off); archive / mute / pin (≤ 4, pin unarchives, archive unpins) / mark unread / nickname / note — all written back to storage (`StorageWriteBack`).
- **Identity** (`Identity/Identity.swift`): safety numbers (5200 iterations, version 2, ACI; digits and QR), verify/unverify with verified-change notices and the Verified sync both ways (a different key from the phone is a key change); usernames over libsignal's Accounts services (candidates or a chosen discriminator within `global.nicknames.min/max`, reserve, confirm with a new link, delete, reset link, look up by username or signal.me link; stored and written back); key transparency (`keyTransparencyClient` contact and self checks over `key_transparency_account_data` + `lastDistinguishedTreeHead`, availability from `desktop.keyTransparency.*` and the AccountRecord switch, upstream's self-health transitions).
- **Since added**: blocking or deleting a group from a message request leaves it, accepting accepts a pending invite and downloads the media that waited (`respondToMessageRequest(groups:)`); `AttachmentStore.deleteOrphans` removes files no attachment, sticker or avatar refers to (`cleanupOrphanedAttachments`).
- **Simplified / not yet**: story reactions and story deletes (stories are Phase 7); per-recipient send state of outgoing reactions; edits change the body and previews only; spam reports are local (no server report); expiry, pin expiry, orphan cleanup and the weekly key-transparency check are functions for the app to schedule; the mock server has no key-transparency service, so only the store and error bookkeeping are tested; the app target still does not link SignalCore (views run on demo data).
- **Tests**: ModifierTests (reactions incl. early arrival, outsider rejection, ours + phone's; deletes incl. wrong author and too old; edits; polls; pins incl. limit and expiry; view-once; delete for me), ConversationStateTests (timers incl. versions, read start, expiry, ours, universal; requests incl. no media before accept, phone BLOCK; blocking sync; chat settings in storage, pin limits), IdentityTests (safety number equal to alice's side computed by the mock's libsignal, QR match, verify sync both ways; usernames end to end on the mock's gRPC; key-transparency store and self check). `swift test`: 110 tests in 27 suites pass; lint ok; the app builds.

## Decisions (user, 2026-11-05): Phase 4 scope closed

- **App integration is its own later step.** Phase 4 is complete at the SignalCore level. The app target does not link SignalCore yet; account bootstrap, the linking screen, services and view models come in a separate app-integration step. The sticker manager panel (data ready in `Stickers.managerState`) will be its first live view.
- **Key transparency is accepted at mock level.** The tests cover the store, self-health handling and error paths against the mock server, which has no key-transparency service. An end-to-end self and contact check against Signal's staging service is a manual release-time item.
- Call links (refresh jobs queued by storage sync) stay with Phase 6 (calling), as planned.
- For the record, the hook's other "missing" items are in the code: sender-key sends with sealedSenderMultiRecipientEncrypt (`Messaging/GroupSender.swift`), group-send endorsements in both tables (`Groups/GroupSendEndorsements.swift`), every group-change builder (`Groups/GroupActions.swift`), group-change rendering (`SignalUI/Components/Conversation/GroupV2Change.swift`), CDN3 TUS and CDN2 resumable upload (`Attachments/AttachmentUploader.swift`), the download manager with visible-first priority and backoff (`Attachments/AttachmentDownloadManager.swift`), quarantine properties on save (`Attachments/AttachmentStore.swift`), and favicon fallbacks in link previews (`SignalCodecs/Sources/HTMLMeta`).

## Status (2026-11-05): Phase 5 — ContainerMP4 and AudioAAC done

- **ContainerMP4** (`SignalCodecs/Sources/ContainerMP4`): grammar + demuxer for progressive ISOBMFF (ftyp, mvhd, tkhd with rotation from the matrix, edts/elst, mdhd, hdlr, stsd with avc1/avc3+avcC and mp4a+esds incl. the QuickTime `wave` box, stts, ctts v0/v1, stss, stsc, stsz/stz2, stco/co64), limits on boxes, depth, tracks, samples and table entries, every offset checked against the file size; a truncated final mdat stays demuxable. `presentationOffset` (first non-empty edit) gives presentation times. `MP4File.storyCheck` ports `isVideoGoodForStories` (avc1, ≤ 30.999 s). Tests: every sample of 6 ffmpeg-made fixtures equals ffprobe (size, offset, pts, dts, keyframe; faststart and moov-at-end, B-frames, rotation, audio-only, GIF-like), plus co64/stz2/rotation and hostile structures.
- **AudioAAC** (`SignalCodecs/Sources/AudioAAC`): AAC-LC decoder: AudioSpecificConfig (incl. explicit and backward-compatible SBR signalling; HE-AAC decodes its LC core at the core rate, SBR not applied), ADTS framing (ID3, CRC, truncated tail), raw_data_block with SCE/CPE/LFE/DSE/FIL (CCE, PCE, prediction and gain control refused), section data, scalefactors, pulses, TNS, spectral Huffman books 1–11 with escapes, M/S, intensity stereo, PNS (FFmpeg's LCG, so noise matches too), IMDCT as a DCT-IV over an FFT, sine/KBD windows, all four window sequences with FFmpeg's handling of invalid transitions. Huffman and band tables generated from FFmpeg's aactab.c by `Tools/gen-aac-tables.py`.
- **Tests**: AACTransformTests (DCT-IV and IMDCT against the direct O(N²) formulas, window power complementarity); AACReferenceTests: 9 fixtures (ffmpeg native and Apple AudioToolbox encoders, ADTS and M4A, 8–48 kHz, mono/stereo, PNS on/off, low bitrate with intensity stereo, a hand-written stream with pulse data) decode within 2.4e-7 of ffmpeg's decoder (≈136 dB SNR); a coverage test proves the fixtures use short windows, transitions, M/S, intensity, PNS, TNS, pulses, escapes and KBD; AACStructureTests (HE-AAC core, ADTS ID3/CRC/truncation/garbage/profile, ASC variants and refusals, wrong channel count, every truncation of 12 frames and 3000 bit-flip mutations per fixture throw or decode to finite frame-sized output). Lint now also bars SignalCore from Container*/Audio*/Video* modules.
- **Not yet**: SBR/PS (HE-AAC plays band-limited at the core rate), 960-sample frames, routing through the media service (with the other Phase 5 decoders).

## Status (2026-11-05): Phase 5 — AudioMP3 (decoder and voice-note encoder) done

- **Decoder** (`SignalCodecs/Sources/AudioMP3`): MPEG-1/2/2.5 Layer III. `MP3Stream` frames the stream (ID3v2 incl. footers, ID3v1, APEv2, resync byte by byte, a frame is accepted only when its successor confirms it until the stream is locked, a truncated final frame is kept, free format and Layers I/II refused) and reads the Xing/Info + LAME tag (frames, bytes, encoder delay/padding; also VBRI) → `durationSeconds` after delay and padding. `MP3Decoder`: side info, bit reservoir and FFmpeg's handling of lost/overrun granules, MPEG-1 scalefactors with scfsi and LSF partitions incl. the intensity-stereo case, Huffman big values (all 32 table selects, linbits) and count1 (A/B), requantisation, M/S, intensity stereo (MPEG-1 and LSF), short/mixed reorder, alias reduction, IMDCT 36/12 with block windows and overlap, frequency inversion, polyphase synthesis; follows mono/stereo mode changes (`decode(_:channels:)` maps to a fixed layout). Tables generated from FFmpeg n7.1 by `Tools/gen-mp3-tables.py`. CodecCore gained `PrefixCodeTable` (table-driven MSB prefix codes; AAC now uses it too), `MSBBitCursor` (seekable, zero-filling) and `MSBBitWriter`.
- **Decoder tests**: 11 LAME fixtures (VBR/CBR, joint and simple stereo, 8–48 kHz) and the 10 ISO 11172-4 compliance streams from FFmpeg's FATE suite (`Tools/gen-codec-references.py mp3 mp3conformance`) all match ffmpeg's float decoder within 4.5e-6 (≈ 130 dB SNR); a coverage test proves short, mixed and start/stop blocks, M/S, intensity, scfsi, count1 table B, CRC and every Huffman table are exercised; framing tests (tags, junk, false syncs, refusals, duration); every truncation and 3000 bit-flip mutations per stream decode to finite frame-sized output or throw.
- **Encoder** (`MP3Encoder`, for voice notes): upstream's settings (LAME VBR-mtrh, V7, ≤ 90 kbps, mono; `Signal-Desktop/packages/lame/wrapper.c`), including LAME's resampling of 44.1/48 kHz input to 32 kHz (V7 lowpass 14.9 kHz). Polyphase analysis + MDCT (reconstructs through our decoder to the filterbank's precision), attack-driven block switching with start/stop windows, an MDCT-domain masking model (Schroeder spreading, per-band tonality, ISO model 2's minimum SMR, Terhardt ATH), a direct VBR quantiser (per-band coarsest step within the allowed noise, scalefactors / scalefac_scale / preflag / subblock gains, scfsi), exhaustive Huffman region and table choice, per-frame lowest bitrate with the bit reservoir and requantisation over the cap, and the Xing + LAME-format tag (frames, bytes, TOC, delay 528 / padding, music and tag CRCs). Same API shape as upstream's wrapper (`encode` chunks, `flush`, `tagFrame()` to overwrite the placeholder).
- **Encoder results** (3 s voice-like test signal, 48 kHz in): 54 kbps, 17 dB SNR; LAME -V7 on the same signal: 55 kbps, 19 dB. ffmpeg decodes our files without errors. Known gaps: ≈ 2 dB SNR behind LAME at equal rate; MPEG-2 rates (16/24 kHz input) cost more than LAME (up to 70 kbps); the tag names our encoder ("SgSafe1.0") rather than "LAME", so FFmpeg-based players (e.g. upstream Desktop) do not trim the 1057-sample delay (they show ≈ 0.06 s more duration); our own parser verifies the tag CRC and trims.

## Status (2026-11-05): Phase 5 — Playback done (service side, engine, scrubber)

- **Media service** (`SignalMediaService`): `audioSummary` (duration, rate, channels and upstream's waveform: `WaveformBuilder` / `toPeak` ported into MediaXPCInterface, over the interleaved samples; empty beyond `MAX_AUDIO_DURATION` 15 min) and `decodeAudio(startFrame:maxFrames:)` (chunks of the presentation timeline) for MP3 and AAC in ADTS or MP4/M4A, sniffed from the bytes. Timelines apply the trims players do: MP3 LAME/Xing delay + 529 and padding, the MP4 edit list (start and length; HE-AAC core rate), none for ADTS. Chunks decode a few frames early (MP3 reservoir ≥ 512 bytes back + overlap; AAC one frame) and are sample-exact with a decode from the start, except AAC noise-substitution bands (their generator runs through the stream, as FFmpeg's). Damaged frames decode as silence. Voice notes: `startVoiceNote` / `appendVoiceNote` / `finishVoiceNote` / `cancelVoiceNote` sessions run upstream's recorder (MP3Encoder + waveform of the input + duration; the finished file starts with the final tag frame). Results are re-validated in the main process (`validated()`).
- **Tests** (`SignalMediaDecoderTests/AudioTests`): upstream's waveformBuilder vectors; 6 files (LAME MP3 stereo/mono, ffmpeg and Apple M4A, mono M4A with PNS, ADTS) against ffmpeg's default trimmed decode (`Tools/gen-codec-references.py audioservice`): equal length and waveform (±1); chunks at 7 offsets equal the whole decode; refusals; a voice-note session round-trips to the same duration.
- **Playback** (`SignalUI/Audio/AudioPlaybackEngine`): upstream's globalMessageAudio over AVAudioEngine, PCM only, fed by a `PCMSource` closure (the app connects it to `decodeAudio`); 4 s chunks, two scheduled ahead, the first scheduled before the node starts (the clock never counts a starved start); play/pause/seek/ended; rates 0.5/1.5/2 through AVAudioUnitTimePitch (pitch kept, as `<audio>`), 1× straight to the mixer (exact samples, no time-pitch buffering); rate changes keep the position. Tests render offline (manual rendering): sample-exact output, clock, seek, pause, ended, 2×, rate changes.
- **PCM into AVAudioPCMBuffer** needs one audited `unsafe` (`SignalUI/Audio/PCMBuffer.swift`, mutableChannelData's MutableSpan): approved by the user 2026-11-05 since macOS 27 has no safe write API; the lint allows exactly that line besides the Keychain read, and no longer mistakes AVAudioPlayerNode for the banned AVAudioPlayer.
- **UI**: `WaveformScrubber` (click to a ratio, first 2 bars rewind; ↑/→ ↓/← 1 s, Page Up/Down 5 s, passed through upstream's ratio-as-seconds `onScrub` quirk; slider accessibility), MessageAudio's active state (pause button, countdown of the remaining time, scrubbing, `toggleIsPlaying` / `updatePosition` as upstream), PlaybackRateButton message variants (incoming/outgoing colours, `margin-block: -2px`, always laid out, scaled in while playing). TimelineMessage audio stories still match Storybook.
- **Not yet** (app integration): the global player state (upstream's audioPlayer duck: active message, consecutive voice-note autoplay, mini player), microphone capture for recording (AVAudioEngine input tap → safe AVReadOnlyAudioPCMBuffer reads), the XPC transport.

## Status (2026-11-05): Phase 5 — VideoH264 decoder done (bit-exact, ≥ 30 fps 1080p)

- **Decoder** (`SignalCodecs/Sources/VideoH264`): Baseline/Main/High (progressive 8-bit 4:2:0): NAL/RBSP/Exp-Golomb, SPS (scaling lists, VUI reorder/colour), PPS (8x8 transform, scaling lists rule A/B), slice header (list modification, explicit weights, MMCO); CAVLC and CABAC behind one entropy protocol and a single macroblock layer (I_NxN 4x4/8x8, I_16x16, I_PCM, P and B partitions and sub-macroblocks, skip); intra prediction (4x4/8x8 with reference filtering/16x16/chroma, constrained intra); MV prediction, P_Skip, spatial and temporal direct with direct_8x8_inference; 6-tap/bilinear motion compensation; explicit and implicit weighted prediction; scaling + 4x4/8x8 transforms and DC transforms; deblocking with all bS rules; POC types 0/1/2, sliding window + MMCO 1–6, P/B list initialisation and modification, reorder-delayed output, cropping. Tables from FFmpeg n7.1 by `Tools/gen-h264-tables.py`. Refused: interlaced (field/MBAFF), FMO/ASO slice groups, data partitioning, SP/SI, 4:2:2/4:4:4, high bit depth, lossless.
- **Bit-exact**: 14 x264 fixtures (`Tools/gen-codec-references.py h264`: Baseline intra/P/3 refs/4 slices, Main CABAC intra/P with 4 refs and weightp/B spatial and temporal direct with B-pyramid and weightb, High 8x8+JVT CQM, High CAVLC 8x8, deblock offsets, deblocking off, odd size with cropping, constrained intra, 1080p30 at 8 Mbit/s) match ffmpeg's framemd5 for every frame.
- **Parallel decode**: parsing (entropy decoding + motion derivation) is serial and stores levels and partition layouts; reconstruction and then deblocking run as row wavefronts over `DispatchQueue.concurrentPerform`, each macroblock row in its own mutex-protected stripe (published unfiltered border lines for the row below, spin locks, `Atomic` row progress, rows claimed in order). No `unsafe`. 1080p30 High: 21 fps single-threaded → 33 fps with 4–8 workers, 37.6 with 12 (on a machine already at load 3.3). Next speed-up when needed: overlap the parse of picture N+1 with the reconstruction of N (parse is now ≈ 55 % of the time).
- **Resilience**: damaged NAL lengths keep the units before them; a failing slice keeps the macroblocks decoded so far; missing macroblocks are concealed (zero-motion copy of the latest reference, or grey) and counted in `errorCount`; pictures whose first slice is lost still start. 300 rounds of bit flips and truncations per fixture (H264_STRESS) decode without a trap, producing nearly every frame.
- **Since done**: the media-service video API and poster frames (see the video pipeline status below).

## Status (2026-11-05): Phase 5 — video pipeline (display, playback, GIFs, Giphy)

- **Display** (`SignalUI/Video`): `VideoRenderer` uploads the three I420 planes as r8 textures (`VideoTexture`, the one audited `unsafe` line approved by the user, `MTLTexture.replace`) and converts Y′CbCr → RGB in the fragment shader (BT.601/709, limited/full range). The rotation, matrix and range are compiled into the shader as macros (one cached pipeline per combination), so no `setBytes` is needed. Aspect is handled by the viewport (contain, or cover by overhanging the target). `VideoView` (CAMetalLayer, scale from `convertToBacking`, since `NSView.window` is `unowned(unsafe)`). Tests render offscreen and read back through CoreImage: colour conversion against the BT.601/709 formulas (±1.5), rotation 0/90/180/270 with letterboxing, and cover.
- **Playback** (`VideoPlaybackEngine`): pulls frames from a `VideoFrameSource` (in the app, a media-service session), keeps 6 queued, and presents the latest due frame (late frames are skipped). The clock is the audio engine's play head when there is sound, otherwise the host clock. Supports seek to the exact frame (decoding forward from the sync frame), looping, pause, and `unload` (closes the session). Malformed or non-increasing frames are dropped. Tests use a fake clock and source, plus the offline audio engine for A/V sync.
- **UI**:
  - Lightbox: plays on show, with working controls (play/pause, time, click-to-seek). GIFs and view-once videos loop without controls; view-once shows the time pill.
  - MessageGIF: loops while the window has focus. With tap-to-play it follows upstream's MAX_GIF_TIME 8 s / MAX_GIF_REPEAT 4 rules (`GIFPlayback`, unit-tested). Uses object-fit cover.
  - FunGif / FunGifPreview: loop muted; under reduced motion they play only on hover or focus, unless `ignoreReducedMotion`.
- **Giphy** (`SignalCore/Gifs/Giphy.swift`):
  - Search and trending through the content proxy, decoded against upstream's strict schema: integer strings, CDN URLs only on media0–4.giphy.com over https, synthetic responses rejected.
  - Queries are cut at 50 UTF-8 bytes.
  - Files are fetched in fixed-size Range segments, 4 in flight, with Content-Length/Content-Range checks. This fixes upstream's last-segment off-by-one (a request one byte past the end when length % segment == segment − 1).
  - Tests use a fake transport.
- **FunPanelGifs** (SignalUI):
  - Search with a 500 ms debounce; the sub-nav has Recents and 8 categories.
  - Two-lane waterfall placed like tanstack-virtual lanes. Paging is 10, then 30, fetched near the end.
  - Players are created per item while it is in view.
  - GIPHY attribution pill until the first scroll.
  - Snapshot of FunPicker `Default` on the GIFs tab: 0.09 % (captured with the new `CAPTURE_CLICK_PAGE` / `CAPTURE_FOCUS` options of Tools/capture-storybook.mjs).
  - FunSubNav now sizes items like CSS `flex: 1`, which also brought the existing picker snapshots to ≤0.2 %.
  - Not ported: the long-press GIF lightbox and arrow-key waterfall navigation.
- **App wiring still to do**: a `VideoFrameSource` over `MediaProcessing.openVideo/videoFrames/seekVideo/closeVideo`. The FunPanelGifs data source is GiphyClient + media-service players; the picker can show ~20 GIFs at once, so `VideoLimits.maxSessions` (4) must be raised, or the visible players capped. - **Outbound video** (`SignalCore/Attachments/VideoAttachments.swift`):
  - `prepare` passes video/mp4 through libsignal's Mp4Sanitizer (mp4san). It validates the box structure, puts the metadata before the media data, and drops top-level extras.
  - mp4san keeps `moov/udta` (titles, location). Stripping it would go beyond what upstream does.
  - Unsupported inputs (fragmented MP4, QuickTime) are sent as is, as upstream Desktop does.
  - Videos get a PNG screenshot (the media service's poster), display size and duration (`handleVideoAttachment`); file names of videos are dropped.
  - Downloaded videos get a screenshot (`captureDimensionsAndScreenshot`).
  - The `screenshot*` and `duration` columns are now mapped.
  - The Swift wrapper is moved to the typed-handle API, and the six mp4 FFI declarations are added to the header (Tools/vendor-patches/libsignal-media.patch).
  - Tests: moov-last → ftyp/moov/mdat with identical frames, a faststart file, junk, and `prepare` end to end.

## Status (2026-11-05): Phase 5 — media editor (SignalUI/Components/MediaEditor)

- **Model** (`MediaEditorModel.swift`):
  - Image state (angle, crop, flips, canvas size) and objects: pencil paths, text, stickers, digital and analog clocks. Objects have Fabric's geometry (centre, angle, scale).
  - Upstream's rotate, flip, crop and reset operations; snapshot history (1000, undo stops at the initial state); the hue colours; Fabric 4's pencil decimation and quadratic-midpoint path.
  - **Fix**: upstream's crop ignores flips (Fabric applies the flip after the source crop, so a crop after a flip kept the mirrored region). Here the crop goes through the inverse image transform, which is identical to upstream's per-angle table when nothing is flipped (tested for all four angles).
- **Rendering** (`MediaEditorCanvas.swift`): one renderer for the zoomed Canvas and the full-size export.
  - Text uses CoreText in a CGContext (stroke mode for Outline; Fabric's line and baseline metrics).
  - Clocks: Hatsuishi digital, and the analog dials and hands generated as Shapes by gen-icons (`analog-time/*`).
  - Overlays: selection border; delete, resize and rotate controls; More styles; crop rectangle with corners and a 40 % outside shade.
  - RGBA → CGImage goes through `CIImage(bitmapData:)`, because CGImage's own initialiser takes a pointer.
- **Interaction** (`MediaEditorState.swift`):
  - Select and move objects; resize from the bottom-right control (anchored at the top-left corner); rotate; delete; clock style cycling.
  - Pencil and highlighter. Text mode: new text at a tenth of the shorter side, typed in a field over the object; blank text is removed on leaving.
  - Crop session: presets, corners with an optional aspect lock, move, contained and only shrinking; rotate, flip, reset.
  - Shortcuts: Esc, ⌘D/T/C, ⌘Z/⌘⇧Z, Delete, arrows (⇧ ×20, ⌥ rotates).
  - The sticker picker gains upstream's "Featured" time stickers (`FunPanelStickers.timeStickers`).
- **Export**: JPEG at quality 92 (Chromium's canvas default), labelled **image/jpeg** (upstream labels the same bytes image/png), plus a blurhash of a ≤200 px rendering.
- **Tests**:
  - The six MediaEditor stories at ≤0.19 % (captured with the new `CAPTURE_VIEWPORT=1`).
  - Geometry and history tests.
  - Interaction tests (draw, sticker, move, deselect and reselect, delete control, undo/redo, text mode).
  - Crop + rotate export decoded with the Swift JPEG decoder (orientation checked).
- **Not ported**: Fabric's in-canvas text cursor and selection (a text field is used while typing), the long-press sticker lightbox, and the caption's mentions and formatting (CompositionInput's plain mode).

## Status (2026-11-05): Phase 5 — fuzz targets (codec-fuzz)

- `codec-fuzz` gains `mp4`, `h264`, `aac` and `mp3` targets (Sources/codec-fuzz/Media.swift), seeded from Tests/DifferentialTests/Resources (files ≤ 200 KB). Each run is deterministic from (seed, iteration); `--dump` writes the input.
  - **h264, aac, mp3:** structure-aware. Each seed is parsed once into units (H.264 samples with their SPS/PPS, AAC access units from ADTS and MP4, MP3 frames), and the mutations act on the units, so inputs keep their framing and reach the entropy decoders.
  - **mp4:** box-aware byte mutations (bodies, sizes and types, 32-bit fields set to edge values, deleted and spliced boxes, truncation), then the demuxer and every sample through H.264 / AAC.
- **ASan smoke run (seed 7):** MP4 20,000, AAC 20,000, MP3 20,000 and H.264 4,000 inputs, no crashes. Outcomes reach deep parsing: AAC scalefactors and TNS, MP3 granule side info, H.264 mostly concealed pictures.
- Run: `swift run -c release -Xswiftc -sanitize=address codec-fuzz <target> Tests/DifferentialTests/Resources/<MP4|H264|AAC|MP3> [iterations] [seed]`. These remain smoke runs, not a CI gate (see the fuzzing decision above).

## Decision + status (user, 2026-11-05): metadata is stripped from outgoing images and videos

- **SignalCodecs `MetadataStrip`** (runs only in the media service, `MediaProcessing.stripMetadata`):
  - **JPEG:** keeps the JFIF header (no thumbnail), the ICC profile, Adobe, the tables and the scans. Drops Exif/XMP (APP1), MPF, IPTC (APP13), all other APPn, COM and data after EOI. An orientation ≠ 1 is kept as a one-tag Exif block.
  - **PNG:** drops tEXt, zTXt, iTXt, eXIf and tIME. **WebP:** drops EXIF, XMP and unknown chunks, clearing the VP8X flags. **GIF:** drops comment and non-loop application extensions.
  - **MP4/QuickTime:** drops udta, meta, uuid, free and skip boxes and non-media top-level boxes, zeroes the mvhd/tkhd/mdhd times, and moves stco/co64 offsets.
  - **HEIC/HEIF/AVIF:** zeroes the Exif and XMP items in place (iinf + iloc).
- **SignalCore `AttachmentServices.prepare`:** an image or video that was not re-encoded (GIFs, images the scaler cannot decode such as HEIC until Phase 8, videos, `transcode: false`) is stripped before anything else. If it cannot be stripped it is refused (`OutgoingAttachmentError.metadataNotRemovable`), never sent with its metadata. Non-visual files (documents, audio) are sent as they are.
- **Tests:**
  - Fixtures from Tools/gen-metadata-fixtures.sh (exiftool: GPS, make/model, dates, XMP, IPTC, comments).
  - MetadataStripTests: no metadata left, same decoded pixels/frames, the JPEG still upright, video times zero, HEIC structure unchanged, malformed input throws.
  - SignalCore: no metadata leaves for any fixture with or without transcoding; unstrippable inputs are refused.
  - exiftool on the stripped files shows only structural tags.
- **Lint:** SignalCore may not import MetadataStrip.

## Status (2026-11-06): Phase 6 steps 1–4 (calling core, video, screen share)

- **ringrtc** (`Packages/SignalRingRTC`): our `signal-ringrtc-ffi` cdylib over ringrtc's `native` API (C ABI with `__counted_by` buffers → Swift Span, no `unsafe`), and a Swift `RingRTC` / `Call` / `GroupCall` API after Service.ts. Loopback tests: a 1:1 call connects and ends; NV12 video sent by one side arrives as RGBA at the other; SFU HTTP goes through the app. `send_video_frame` now refuses buffers that are not exactly one frame (WebRTC reads width × height × bpp with no length).
- **CallingService** (SignalCore/Calling): the CallingClass port. Signalling goes through MessageSender (offers urgent; 15 s timeout). Group messages go through GroupSender. SFU HTTP uses HTTPClient. ICE servers come from `/v2/calling/relays` (two entries per relay, cached for the shortest TTL). Membership proofs come from `/v2/groups/token`, and members are sent as encrypted service ids. Also ported: incoming-call policy (blocked, muted, unverified, message request → NeedPermission hangup), peek, ring updates and cancellations, group-call update messages, ad hoc profile keys, presenting, and system mute.
- **Call history:** CallEvent and CallLogEvent syncs, in both directions.
- **Call links:** create, read, rename, restrictions and delete through ringrtc against the SFU, with zkgroup create/auth credentials. The CallLinkUpdate sync and the storage service queue the "call link refresh" job.
- **DRED weights:** OptionalResources fetches the file from updates2, checks its size and SHA-512, and caches it; it is then registered as `opus-dred`.
- **Receive pipeline:** routes CallMessage (`.callMessage`) and the call syncs.
- **Mock server:** the harness reports `genericServerPublicParams` and can inject call syncs. Tools/build-mock-server.sh fixes the mock's `GET /v1/call-link/` route. The SFU base is `/callingService`.
- **Video** (SignalUI/Calling, Video):
  - CameraCapture (AVCaptureSession; format ≤ 960×720@30, or 640×480 for groups; NV12);
  - CaptureFrames: the 4th audited `unsafe` line, approved 2026-11-06, copies locked pixel-buffer planes;
  - RemoteVideoView (display-link pull of ringrtc RGBA into Metal; VideoTexture's audited line now also uploads rgba8);
  - LocalVideoView (mirrored preview).
- **Screen share:**
  - ScreenShareCapture (ScreenCaptureKit, ≤ 2880×1800@5, NV12, last frame repeated every second);
  - SystemScreenPicker (SCContentSharingPicker; the selection crosses actors as ids);
  - CallingSelectPresentingSourcesModal with SCK thumbnails;
  - NeedsScreenRecordingPermissionsModal and ScreenRecordingPermission;
  - CallingScreenSharingController with its 480×44 floating panel (excluded from capture);
  - MuteState (AVAudioApplication).
- **Tests:** SignalCore 126 + CallingTests 6; SignalRingRTC 4; SignalUI CallVideoTests 3 and ScreenShareSnapshotTests (controller 0.07%; source modal 0.43% overall, with a documented 1.5% tolerance in the dialog for SwiftUI's 0.5pt row snapping).
- **Next:** step 5 (the calling UI: CallManager, CallingLobby, CallScreen, …), then wiring CallingService, the capturers and MuteState in the app session.

### Phase 6 step 5 progress (calling UI, SignalUI/Calling)
- **Ported and matched against Storybook** (≤1% per story, light and dark): CallingButton (10), CallingHeader (2), IncomingCallBar (7), CallingPreCallInfo (21), CallingLobby (15), GroupCallRemoteParticipant (8), CallingPip (12; the lonely stories show only Chromium's fake camera), CallingScreenSharingController (3), CallingSelectPresentingSourcesModal (1), CallScreen (12 so far: pre-ring, ringing, accepted, ended, reconnecting, group 0/1, outgoing ring, group reconnecting, hand raised).
- **GroupCallRemoteParticipants:** the paging, row-packing and best-scale arrangement are ported as `GroupCallGridLayout`. A geometry test reproduces all 50 tile rects of the many-participants paginated capture (random aspect ratios read back from its DOM). Static rendering draws one pulled remote frame (`RemoteVideoStack`), so Storybook's solid-colour fake frames are compared too.
- **Shared pieces:** CallControlsBar, CallBackgroundBlur, CallingLobbyJoinButton, CallParticipantCount, CallingStatusIndicatorHandRaised, CallingAudioIndicator, CallingConversation, and `callingTextShadow`.
- **Captured but not compared:** the CallingAudioIndicator stories, which are time-animated.
- **Snapshot harness:** `Snapshot.assertMatches(…, ignoring:)` excludes rects where Storybook plays fake camera or remote video streams.
- **Ported 2026-11-06 (second batch, all ≤1% light and dark):** CallingParticipantsList (4), CallingRaisedHandsList + its button (7), CallingPendingParticipants compact/expanded (6, plus the approve-all / deny-all confirms), CallingAdhocCallInfo (6, unknown contacts folded into one row), CallLinkDetails (9), CallLinkEditModal (2), CallLinkAddNameModal (1), CallLinkPendingParticipantModal (3), CallQualitySurveyDialog (1 story: the first page; all three pages ported). ConfirmLeaveCallModal and CallDiagnosticWindow are ported (no stories).
- **Fixes found on the way:** CSSText `break-all` now breaks before an overflowing ordinary break (URLs); the hand-raised pill is a fixed 28pt high; the participants-list close button tints its icon when focused instead of filling a square.
- **Ported 2026-11-06 (third batch):** CallingDeviceSelection (4 stories), CallManager (15 of 17 captured stories: the call-link lobbies with the participants panel, the call screen with join requests incl. unknown / system contacts and the panel open, ongoing 1:1 and call-request-needed; stage routing unit-tested), CallNeedPermissionScreen, and the Calls tab (CallsTab, CallsList, CallsNewCall, CallsNewCallButton; no stories, row rules unit-tested). CallScreen now shows the raised-hands button and list and the pending-participants card.
- **CallManager stories not compared:** ongoing-group-call (Storybook grows the viewport to 1006px around the lonely full-size preview) and call-link-with-unknown-contacts (random demux ids pick the tile order and fake-frame colours).
- **CallScreen, fourth batch (≤0.43% each):** pre-ring / ringing / reconnecting with avatar, has-remote-video, self-view-expanded, someone blocked, missing media keys (blurred avatar, `titleNoDefault` in the notice), speaker view (the overflow column gained its static-rendering fallback), someone sharing screen (and reconnecting), the screen-recording permission warning (in the app theme over the always-dark call; its numbered steps now wrap under the marker as `list-inside` does), and suggest-lower-hand. 
- **Call toasts:** `CallingToastQueue` (keyed toasts with lifetimes, paused on hover, capped) and `CallingButtonToasts` (muted / ringing / raised hands / lower-hand suggestion / muted by / observed remote mute, each fired on a state change as upstream's hooks do), shown 16pt above the controls; the rules are unit-tested.
- **Reactions:** `CallReactionsModel` (one toast per reaction, newest at the bottom, 4th/5th faded; bursts when 3+ people send the same emoji within 4s, at most 3 per 4s) and a floating-emoji burst view; group-call-reactions-many-in-order matches (0.21%), the burst rule is unit-tested.
- **Also ported:** CallingParticipantMenu (its story matches 0.00%; the participants-list "more" button opens it, with the remove/block confirm), DirectCallRemoteParticipant as its own view (a render test checks the remote frame is drawn), and the reaction picker over the controls (`min(44%, 32vw)` in, 70px up; picking sends `sendReaction`).
- **Not compared:** the toast-a-palooza / remote-mute / hand-raising / both-speaking / many-* stories (animated, or 7000px-tall captures). The app shell now shows the real Calls tab over demo call history; the app now links SignalCore and SignalRingRTC (libsignal static, ringrtc as libsignal_ringrtc.dylib, so the two Rust runtimes never share a binary image: the Phase 0 duplicate-symbol risk does not arise), and `SIGNALSAFE_RINGRTC_SMOKE=1` starts the calling engine at launch (verified). Wiring CallingService, the capturers and MuteState into a session waits for the app session (no linked-account plumbing in the app yet, as for Phases 2–4).

## Status (2026-11-06): Phase 7 — remaining parity (all items implemented; app wiring pending)
- **Scope rulings:** donations stay out (as before); debug log upload and the auto-updater are omitted (user, 2026-11-06).
- **Stories UI (SignalUI/Stories), matched to Storybook (≤1%, light and dark):** TextAttachment (15 of 17), StoryLinkPreview (10), StoryImage (11 of 12), StoryListItem (1), MyStoriesButton (5), MyStories (4), StoriesTab (4), StoryViewer (8 of 10). StoriesPane, StoriesAddStoryMenu, the hide/delete confirms and the viewer's menus are ported with them.
  - Not compared: TextAttachment romeo-juliet / link-preview-wrj (Parisienne, a hinted TrueType script font: Chromium's advances are ~0.8% narrower than CoreText's and HarfBuzz's, and rounding them did not reproduce its lines); StoryImage video and StoryViewer multi-story (Storybook plays a JPEG as the video); StoryViewer long-caption (Chromium's 90px backdrop blur stays sharp near the right and bottom edges).
- **Shared fixes:** AxoPopper keeps nested poppers (a tooltip on a menu's trigger); NavSidebar with no stored width fills its container, narrow; CSSText-independent `normalLineHeight`; `StaticAwareScrollView` for snapshot rendering; the viewer backdrop is the picture at its natural size, tiled (the inline `background:` resets `background-size`).

- **More Stories UI:** StoryDetailsModal (4), StoryViewsNRepliesModal (18), StoriesSettingsModal (8, plus DistributionListSettings / EditMyStoryPrivacy / EditDistributionList / GroupStorySettings pages), SendStoryModal (12), TextStoryCreator (8; Tools/capture-storybook.mjs now finds `.StoryCreator` portals), all ≤1%. The views/replies tabs scroll with the list (upstream's are sticky).
- **Stories data (SignalCore/Stories):** StoryStore (24h `story` rows, `storyReads`, distribution lists with storage write-back), receive (profile-sharing gate, group stories, sent-story syncs per list, recipient updates, replies and reactions by `storyContext`), send (`sendStory` to lists and groups, sealed with `story=true`; `sendStoryReply`; `markStoryViewed` with view receipts). Group stories go to each member, not by sender key. 7 mock-server tests.
- **Received messages** now keep `bodyRanges` (mentions, styles), `mentionsMe` and `quote`.
- **Notifications:** SignalCore/Notifications (notification profiles + schedule = `findNextProfileEvent`, should-notify rules: unread incoming, muted chats only for mentions/replies in groups, profiles, group story replies; Dock badge = `countAllConversationsUnreadStats`), SignalSafeSystem/SystemNotifications (UNUserNotificationCenter, name and message / name only / count, sound, draw attention, badge). Sounds: Tools/gen-sounds.sh (afconvert at build time into Contents/Library/Sounds).
- **Chat folders data:** SignalCore/ChatFolders (`isConversationInChatFolder`, create / ensure All chats / toggle / reorder / delete tombstones / expiry, storage write-back). The pages were already ported (Phase 3).
- **Platform:** spell-check (NSTextView continuous spell checking, no autocorrect), screen security (`NSWindow.sharingType`), display sleep during calls (ProcessInfo activity), start at login (SMAppService), crash reports (macOS's own `.ips` reports instead of Crashpad minidumps: libsignal's Minidump is Node-only and Crashpad is C++).
- **Exports:** username QR card PNG (300 dpi, PNGEncoder gained pHYs); account keys PDF (Letter, rendered page; raster since a CoreGraphics PDF context needs pointer APIs); plaintext export (Backups.proto generated; account, recipients, chats, standard and sticker messages, folders, profiles → libsignal BackupJsonExporter → main.jsonl + media files) and its workflow dialogs (22 ≤1%). System notices, calls and stories are not in the plaintext export.
- **Sticker creator:** EncodeWebP (VP8L lossless: subtract-green, LZ77, prefix codes; libwebp-valid), MediaProcessing.stickerImage (contain to 512, APNG checks) in the media service, SignalCore StickerPackUpload (V1 encryption, manifest, S3 multipart forms), SignalUI StickerCreator window (drop / emoji / details / upload / share) with the creator's 82 strings merged into SignalI18n. Upstream encodes lossy VP8 q0.8; no Storybook stories exist for the creator.
- **App shell:** screen security, spell-check (read at launch), display sleep (`isCallActive`), start at login, notification permission and the crash-report count are wired into AppModel/AppDelegate. Everything that needs an account or the XPC media service (stories, folders and notifications from real data, exports, the sticker creator) waits for the link milestone; the app still shows demo data.

## Status (2026-11-06): linking milestone — the app runs on SignalCore

- **XPC media service:** `SignalMediaDecoder.xpc` (Packages/SignalMediaService: `MediaXPCHandler` + `SignalMediaDecoderService` executable) is bundled in `Contents/XPCServices`. Its only entitlement is App Sandbox, and it runs under the hardened runtime. The app talks to it through `MediaXPCClient`: a binary-plist `MediaRequest`, a watchdog timeout, relaunch on interruption, and every result re-validated. The new `displayImage` request returns RGBA (EXIF orientation applied, fitted to 1024), so the app never parses an image format. Tested in-process through an anonymous `NSXPCListener`, and in the real app bundle.
- **App:** `SignalSession` opens `SignalClient` (production by default; data in `~/Library/Application Support/signal-safe`; `SIGNALSAFE_ENV=staging` uses `signal-safe-staging` and its own Keychain key). It resumes the stored account or shows the install screen with the QR code from `link(onURL:)`, mapping errors as upstream: 409 TooManyDevices, 499 TooOld, QR expiry → retry. After linking it requests contacts/blocked/configuration/keys syncs and a storage-service sync (no history import).
  - Inbox and timeline are live from the database (GRDB ValueObservation: `inboxUpdates`, `timelineUpdates`, `contactUpdates`).
  - The composer sends 1:1 and group text.
  - Message-request actions are wired, and accepting downloads the held media.
  - Image attachments render through the service.
  - Grouping, metadata hiding and date headers follow upstream's `timelineUtil` (SignalUI `TimelineUtil`).
  - Upstream's `SmartHeroRow` wrapper is ported as `HeroRow`.
- **Bundle:** Tools/build-app.sh bundles SQLCipher.framework and libsignal_ringrtc.dylib in `Contents/Frameworks` and drops the build-tree rpath. It fails the build if decoder symbols other than ImagePNG (bundled images only) are in the app binary, or if the service is not sandboxed.
  - Signing: `SIGNALSAFE_SIGN_IDENTITY=<Apple Development / Developer ID identity or SHA-1>`.
  - Ad-hoc builds keep the hardened runtime and add `disable-library-validation`.
- **Mock end-to-end:** `Tools/run-app-mock.py` runs the built app against @signalapp/mock-server. It links by QR, receives a text and a PNG, accepts the request, renders the photo via the XPC service, replies, and checks that Alice received the reply. It captures only the app's window.
- **Not yet:** Real Signal servers are untested (user go-ahead needed). Also outstanding:
  - Sending attachments from the composer, voice notes, stickers and reactions in the timeline UI, and quotes.
  - Typing indicators in the UI, system notifications from receive events, the badge.
  - Stories and calls on real data.
  - QR rotation (upstream rotates the provisioning URL), and sticker creator wiring.

## Status (2026-11-06, evening): linked to the user's real account (production)

- Linked as device 4 after fixing production-only gaps the mock server does not check:
  - `accountAttributes.capabilities` missing from the link request (422).
  - App Transport Security rejecting Signal's private CA for storage/CDN/SFU hosts. Fixed with exact-host exceptions; pinned trust still required, and HTTPClient refuses http and redirects to it.
  - Access-control `UNKNOWN` rejected in group state; upstream accepts it (DESKTOP-9868).
  - Group sends before the group's state is fetched. Now fetched on demand.
- Startup sync:
  - Storage sync (1,231 contacts, 204 groups, account, 94 other records).
  - Then `SignalClient.refreshIncomplete()`: groups without state and stale profiles, four at a time, each group capped at 90 s. Groups the server says we are not in are marked left.
- Titles follow upstream `getTitle`: nickname, system name, profile name, number, username, shared name.
- Profile avatars: downloaded from CDN0 for accepted chats and people in a group with us, AES-GCM decrypted with the profile key, stored encrypted at rest as `profileAvatar`, decoded for display by the XPC service.
- App:
  - The ✏️ compose list uses upstream's composable rules.
  - Settings (General, Appearance, Chats, Privacy) via SignalCore `AccountSettings` with storage write-back.
  - Attachments from the 📎 menu.
  - `SIGNALSAFE_TRACE=1` logs event kinds, counts and error kinds only.
- Data: `~/Library/Application Support/signal-safe`, separate from Signal Desktop's `Signal` folder.

## Status (2026-11-06, night): Phase 7 wired into the app on real data

- Notifications:
  - Received messages and story replies go through `NotificationPolicy.pending`, which applies the mute, mention, profile and read rules, then to `SystemNotifications`.
  - The Dock badge follows `badgeCount` live; clicking a notification opens the chat.
  - Messages arriving in the open chat of the focused window are marked read.
- Stories tab:
  - `StoryFeed`: full text attachments with gradients, and media.
  - Stories grouped by sender or group; My Stories grouped by distribution list.
  - The viewer runs 5 s per story and marks stories viewed.
  - The text creator and media stories go through SendStoryModal to `sendStory` for lists and groups.
- Chat folders: the folder bar with unread and mute stats; inbox filtering by `ChatFolderStore.contains`; mark folder read; Settings → Chat folders list and edit (create, update, delete, reorder, with storage write-back).
- Settings pages:
  - Notifications and While muted (`NotificationSettings.save`).
  - Blocked, with unblock.
  - Profile: names, avatar and username; the username link copies, and the QR card saves as PNG.
  - Account and account keys: OS auth via LAContext; the PDF is saved through NSSavePanel.
  - Internal (local state).
  - Calls is blank until calling is wired.
- Plaintext export: confirm, OS auth, folder choice, `PlaintextExport.export` with progress, then the completed or error state.
- Sticker creator (File menu): images through the XPC `stickerImage`; `StickerPackUpload` encrypt and upload; share link.
- Crash reports: CrashReportDialog when `.ips` reports are pending. **Deviation:** "Send" saves the summaries to a user-chosen file, because there is no debug-log upload.
- Fixes found on the real account:
  - The live timeline content had an exact viewport height, so it never scrolled. It is now a minimum height.
  - A failed SyncMessage.Sent transcript failed and resent delivered messages and marked them Failed. Transcript errors are now logged only, and `markFailed` leaves recipients already sent untouched.

## Status (2026-11-06, late): HEVC (H.265) video decoder — VideoHEVC

User decision: write a Swift HEVC decoder in the sandboxed service, triggered by a Pixel 8
HDR clip (Main10, 1080p, BT.2020 HLG).
- **H1 headers:** hvcC in ContainerMP4; NAL/RBSP, VPS/SPS/PPS (PTL, scaling lists, short-term RPS with inter prediction, long-term, VUI/HRD, range-extension flags), slice segment header (RPS, LT, list modification, pred weight table, entry points). Checked against ffmpeg trace_headers on 12 clips.
- **H2 intra:** CABAC (H.264-shared engine and tables; HEVC context init values), coding quadtree / CU / PCM, MPM, transform tree and units, residual coding (sign hiding, transform skip), QP groups, dequantisation with scaling lists, DCT 4–32, DST, transquant bypass, intra prediction (filtering, strong smoothing, planar / DC / angular).
- **H3 inter:** RPS marking, missing references, DPB bumping with latency, reference lists, merge (spatial / temporal / combined / zero), AMVP, TMVP, 8/4-tap interpolation, default and explicit weighted prediction.
- **H4 loop filters:** deblocking (bS, luma strong/weak, chroma), SAO band/edge.
- **Verification:** Tools/gen-hevc-fixtures.sh generates synthetic clips (x265, and VideoToolbox Main10). ffmpeg supplies goldens: trace_headers and per-frame framemd5. All 12 clips are bit-exact, and the user's 232-frame Pixel clip is bit-exact too (compared with -noautorotate).
- **H5 wiring:** the media service has H.264/HEVC backends. 10/12-bit is rounded to 8-bit, and VideoFrame carries `transfer`. The renderer shader has BT.2020, HLG and PQ to SDR modes (OOTF, 203 cd/m² white, soft shoulder, 2020→709); HDRConvert does the same on the CPU for posters. HEVC is linked only into the XPC service (the build check covers it).
- **H6 speed (done, 2026-11-06):** the user's 1080p10 clip runs at about 64 fps through the decoder alone (232 frames in 3.6 s, bit-exact) and 63 fps through the media service including XPC encoding.
  - **Parser** (the caller's thread): branchless table-driven CABAC; nonzero coefficients go into a sparse per-slice pool. It records plain-data jobs and never reads a sample.
  - **HEVCReconStage** (a serial queue, at most 2 pictures behind): motion compensation plus inter residuals run in parallel, one band per CTB row. Then come the ordered intra steps (their residuals precomputed in parallel), deblocking in CTB-row bands (vertical, then horizontal), SAO, and 8-bit cropped output.
  - **XPC:** video frames use a flat bounds-checked format (`MediaXPCWire.encodeFrames`/`decodeFrames`), not a binary plist.
  - **Player:** VideoPlaybackEngine refills in its own task (queue of 12), so presenting never waits for a fetch.
  - **Parser as a struct:** HEVCSliceDecoder is now a struct, so its state needs no dynamic exclusivity checks. Decoder alone: 69 fps (3.34 s for 232 frames); through the service: 68 fps.
  - **10-bit output:** HEVC playback sessions keep their bits. The decoder packs 16-bit little-endian planes (`packedOutput = .littleEndian16`), VideoFrame and VideoPlanes carry `bitDepth`, the XPC wire format is version 2, and the renderer uploads r16Unorm textures and scales them onto its 8-bit constants. Posters stay 8-bit.
  - **Next, if needed:** the parser is CABAC-bound now, mostly in residualCoding. SAO is still serial.
  - **Untested:** the PCM path has no fixture.
## Decision (2026-11-07): link-preview HTML in its own XPC with a tight Seatbelt profile

User request: "make preview of links work and do that in a separate XPC with a tight seatbelt sandbox profile"; "any image that it renders should be done with our swift decoders".

- `SignalLinkPreviewParser.xpc` (Packages/SignalMediaService: `LinkPreviewParser` library + `SignalLinkPreviewParserService`) parses link-preview HTML (HTMLMeta) and nothing else. The media decoder no longer contains the HTML parser; lint and an `nm` check in Tools/build-app.sh keep the two apart.
- Signed with App Sandbox plus the SBPL rules of `Packages/SignalMediaService/Sandbox/SignalLinkPreviewParser.sb` in `com.apple.security.temporary-exception.sbpl` (Tools/sbpl-entitlements.sh). Finding: App Sandbox's allow rules carry filters and beat unfiltered denies (`(deny default)` or `(deny file-read*)` change nothing), so each deny has a match-everything filter. Result: no file reads (not even system files), no writes (not even its container), no exec/fork, no Mach lookups/registrations, no preferences, no IP or Unix sockets, no IOKit, no POSIX shm/semaphores.
- An SBPL rule that fails to compile is dropped silently, so the service checks at start-up that it cannot read system files or write its container, and exits otherwise (fail closed).
- Tools/check-sandbox-profile.sh: a probe XPC signed with the same entitlements finds every probe denied, and the built parser runs and parses under the profile. (Sandboxed CLI processes trap under the agent's shell sandbox; launchd-started XPC services do not.)
- Fetching stays in the main process (size limits, redirects checked per hop), directly from the site as upstream Desktop does (user decision 2026-11-07): Signal's content proxy answers 403 to CONNECT for ordinary sites (nu.nl, YouTube, Wikipedia) and only passes hosts like Giphy. Preview images are sized and decoded only by SignalMediaDecoder.xpc (our Swift decoders).
- App: the composer fetches the first previewable link 200 ms after typing (setting "Generate link previews" on, no attachments, not editing), shows StagedLinkPreview in the input, Esc/close excludes the link until the next send, and the preview is sent with the message. The timeline shows stored previews with their images.

## Decision (2026-11-09): the media decoder gets the same Seatbelt profile

- SignalMediaDecoder.xpc is now signed with App Sandbox plus `Packages/SignalMediaService/Sandbox/SignalMediaDecoder.sb` (the same deny rules as the parser: no files read or written, no exec/fork, no Mach lookups or registrations, no preferences, sockets, IOKit or POSIX IPC). Decoding needs none of it: bytes in, pixels/samples/encoded files out, threads and memory only.
- Both services call `ServiceSandbox.requireConfinement` (MediaXPCInterface) before serving and exit if the profile is not in force.
- Tools/check-sandbox-profile.sh probes both profiles and drives the real services from the built app through MediaXPCInterface's own clients: PNG/JPEG/GIF/WebP (info, display, thumbnail, scale, strip, sticker), MP3/AAC/M4A, H.264 and HEVC 8/10-bit video, voice-note encoding, and a link-preview page.
- Preset group avatars are encoded by our PNGEncoder in the app (our own drawing, pixels read from the CGImage's data provider); no NSBitmapImageRep.

## Status (2026-11-09): the remaining parity list (calls, voice notes, composer, message extras)

- **Calls (Phase 6 in the app):** `SignalClient.makeCallingService` creates CallingService for the linked account; CallMessages from the receiver go to it. App `Calls.swift` / `CallsView.swift`: CallManager over the window — the lobby (camera preview), direct calls (prering → ringing → accepted, remote video pulled per display refresh, hang up), the incoming bar (accept audio/video, decline; ringtone, Dock attention), group calls (join, participants from remoteDeviceStates, video requested at 640×360), PiP; header call buttons (both for direct chats, video/Join for groups). Camera through CameraCapture (NV12 to ringrtc), display kept awake while a call is up. Calls tab on `CallHistoryStore.groups` (live; consecutive calls with the same peer/type/direction/status within 4 h), new calls, clear history. Settings → Calls: notifications, ringtone, always relay (AccountSettings, upstream item keys), microphone/speaker (ringrtc) and camera. Not yet tested against a real call; call links, screen sharing, reactions/raise-hand UI beyond the screen's own buttons, and group ringing are not wired.
- **Voice notes:** recording via AVAudioEngine's macOS 27 `installAudioTap` (read-only buffers read through spans, no pointer APIs), mono, streamed to the media service's Swift MP3 encoder; sent as audio/mpeg with the voice-message flag. Playback (waveform, seek, speed, next voice note, viewed receipts) in the media service; a mini-player (in place of the pinned bar, and on the empty chat screen) keeps audio across chats.
- **Composer:** grows to 4 lines then scrolls (live only; Storybook renders keep upstream's 72 px); paste of files/PNG/JPEG and drag-and-drop stage attachments; typing indicators both ways (10 s refresh, 3 s idle, 15 s shown; 1:1 and group, `sendGroupTyping`); @mentions (pills, member suggestions, Enter/Tab picks) and formatting (⌘B ⌘I ⌘⇧X ⌘E ⌘⇧B, context menu) through `ComposerController` (AttributedString scope, safe APIs only); sent as U+FFFC + `MessageBodyRange`s; received ranges rendered.
- **Messages:** link previews; inline playback of a lone video; downloads (manual request, cancel, save one/all with dangerous-type refusal and the Saved toast); edit history modal; reaction viewer; retry failed sends (`Messenger.retrySend`); forward from the lightbox; ⌘⇧E reaction picker; text selection + ⌘C in bubbles.
- **Groups:** a photo when creating a group (AvatarEditor dialog, uploaded with `create`); pin offered only when upstream allows it (direct, or admins / attributes open to members).
- **Sync:** account-wide "notify while muted" now writes back (AccountRecord); per-chat already did. Chat colours have no storage-service field (upstream does not sync them either).
- **Find by phone number:** ChooseCountryCodeModal (search by name or calling code).
- **Performance:** timeline rows are Equatable views; scroll state is read only by the overlays; image/sticker/GIF/avatar caches are observed per key; text and shrink-to-fit layouts cache their measurements.
