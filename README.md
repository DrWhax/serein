<p align="center"><img src="Logo/Serein.png" width="128" alt="Serein logo"></p>

# Serein

A native Signal client for macOS. Built with SwiftUI, with every image and video format decoded in Swift inside a sandbox, and a focus on security.

Serein uses its strict Swift calling engine for voice, video, group calls and call links. Open the app normally to use it. Native RingRTC is a separately built reference peer for interoperability tests. [Implementation and interoperability tests](docs/swift-calling-plan.md#implementation-status)

> [!WARNING]
> **Serein is experimental software.** Do not rely on it for strong cryptography or security yet. No one has formally verified that its crypto code is implemented safely.
> If you need strong security, you should use the normal Signal clients. 
> This is also LLM generated code.

Serein is not affiliated with or endorsed by Signal Messenger LLC.

## What it is

- **Native app.** Built with SwiftUI and AppKit instead of Electron. The interface follows Signal Desktop's design closely.
- **Linked device only.** You link Serein to the Signal app on your phone with a QR code. Backups, payments and donations are not supported.
- **Swift media decoders.** Every image, audio and video format is decoded by Swift code in `Packages/SignalCodecs`. Serein never uses ImageIO, VideoToolbox or AudioToolbox on untrusted data. Each format has a grammar-first parser written in the LangSec style. Supported formats:
  - images: PNG/APNG, JPEG, GIF, WebP, BMP/ICO and AVIF (AV1 key frames, 8/10-bit);
  - video and audio: MP4, H.264, HEVC, AAC and MP3;
  - HEIC photos you send are converted to JPEG first, as Signal Desktop does.
- **Untrusted data stays out of the app.** Media, web pages and Giphy's API responses are handled by separate sandboxed XPC services, never by the app. Voice notes are encoded in a service of their own. See [Isolation](#isolation).
- **Signal’s messaging protocol.** Serein uses libsignal for messaging and networking. [libsignal](https://github.com/signalapp/libsignal)

## Isolation

Serein splits work between the app and sandboxed services. Each runs under App Sandbox and the hardened runtime, and has its own Seatbelt profile in `Packages/SignalMediaService/Sandbox`. The profile's rules are added to the sandbox through the process's entitlements.

| Process | What it does | What it can reach |
|---|---|---|
| `Serein.app` | Interface, keys, database, Signal protocol, call signaling and UI | Its own container, the network, camera, files you pick, its crash reports (read-only). It cannot start programs or send Apple events. |
| `SignalCalling.xpc` | Runs the Swift calling engine, including call transport, codecs and audio | Outgoing network and microphone access under the calling sandbox profile. |
| `SignalMediaDecoder.xpc` | Decodes received images, audio and video, converts HEIC | Nothing: no files, network, preferences, devices or Mach services (except the system's code-signing helper, which the peer checks need). |
| `SignalLinkPreviewFetcher.xpc` | Fetches link-preview pages and images | HTTPS to public internet addresses only: not this machine, not your local network. No files, no writes. |
| `SignalLinkPreviewParser.xpc` | Parses the fetched HTML | Nothing, like the decoder. It accepts HTML only from the fetcher. |
| `SignalGifSearch.xpc` | Searches Giphy through Signal's content proxy and parses the replies | HTTPS to the web. Not this machine, not your files, no writes. |
| `SignalVoiceNoteEncoder.xpc` | Records voice notes and encodes them to MP3 | Microphone and audio system access under the voice-note sandbox profile. |

**Link previews.** The app never fetches or parses a web page:

1. The app asks the parser for a private (anonymous) XPC endpoint and passes it to the fetcher.
2. The fetcher fetches the page. It follows Signal Desktop's rules: redirects are followed one hop at a time, every hop must be previewable, and the HTML is limited to 1000 KiB and the image to 1 MiB.
3. The fetcher sends the HTML to the parser over that endpoint and gets back the title, description, date and image link.
4. The app receives the checked result and the image bytes. The decoder checks the image and re-encodes it (GIFs are only checked) before the app shows it.

Pages are fetched directly from the site, as Signal Desktop does. Unlike Signal Desktop, the fetcher refuses a host (on any hop) that resolves to a private, loopback, link-local or other non-public address, so a link cannot point it at your router or printer. It resolves each host itself before connecting. A DNS answer that changes between that check and the connection (DNS rebinding) is not caught.

**Peer checks.**
- Every XPC session is limited, in both directions, to the code signature of the process it expects (`XPCPeerRequirement`, on each service's listener and on each session the app opens). The system ends a session with anything else before a message is delivered.
- `Tools/build-app.sh` writes each component's signing identifier into every bundle's `Info.plist` (`SereinXPCPeers`):
  - With a signing identity, a peer must carry that identifier and be signed by your team with an Apple-issued certificate (`SereinXPCSameTeam`).
  - Ad-hoc builds (the default) can only require the identifier. Anyone can sign another program ad hoc with the same identifier, so use a signing identity for real use.
- The offline services' Seatbelt profiles need no exception for these checks: no Mach lookups and no reads outside their own bundle.
- The app checks every reply for size and type before it uses it.

**Messages between processes.** The services use the XPC framework's sessions with plain XPC dictionaries (`MediaXPCInterface/XPCTransport.swift`), not `NSXPCConnection`: no Objective-C proxies or `NSSecureCoding` decoding. A message holds at most a payload, a listener endpoint and an error string, each read only if it has the expected XPC type, and a payload larger than the receiver expects is refused before it is copied. Requests and replies inside the payload use a strict binary format (`MediaXPCInterface/Wire.swift`), not a general one like property lists:
- The receiver's Swift type decides what is read. The sender cannot choose which objects get built.
- Each call has a size cap that is checked before anything is read. Every length and count must fit in what is left of the message, and trailing bytes are refused.
- The decoded values are then checked against the limits of their type (sizes, dimensions, URLs).

**Containment.** A file can make a decoder hang or crash, so (`MediaXPCInterface/Containment.swift`):
- Every request has a time budget (10 to 30 seconds for media). The app gives up when it runs out.
- Each service runs a limited number of requests at a time and queues a limited number more. Beyond that it answers "busy".
- A request still running a few seconds past its budget makes the service exit, from a watchdog on its own thread. launchd starts a fresh process for the next request.
- The app remembers files that made the decoder hang, or that were in flight when it crashed twice. It refuses them, without sending them again, until it quits.
- Recording runs in its own service, so a decoder that is stopped this way cannot take a recording with it.

**Start-up checks.**
- A sandbox rule that fails to compile is silently dropped, so each process tests its own confinement when it starts. It tries things its profile must deny: reading your home folder, starting a program, and, for the offline services, reading system files.
- If any of these succeeds, or a peer requirement is missing, the process exits.
- `Tools/check-sandbox-profile.sh` checks this from outside (see [Building](#building)).

**Memory safety.**
- Every package and the app are compiled with Swift's strict memory safety checking (`-strict-memory-safety`), with its warnings treated as errors.
- The codec libraries contain no `unsafe` code. `Tools/lint-codecs.sh` enforces this, along with their ban on Foundation and on Apple's media frameworks.

**Calling.** The app sends commands, signaling and video frames over XPC. Each call’s network transport and media engine run inside the calling service. [Service boundary](Packages/SignalRingRTC/Sources/CallXPC)

## Requirements

- macOS 27 on Apple silicon
- Xcode 27 (Swift 6.4)
- A Rust toolchain to build libsignal

## Building

```sh
SIGNALSAFE_SIGN_IDENTITY=<codesign identity> Tools/build-app.sh
open App/SignalSafe/.build/Serein.app
```

`build-app.sh` initializes the libsignal and GRDB submodules, applies vendor patches and builds the libsignal FFI. Interactive builds check for new libsignal releases. The build verifies the signed bundle and checks the calling service’s linker map for native WebRTC and RingRTC.

After “Delete all data”, Serein launches a fresh instance and shuts down the old one. Quit requests allow asynchronous client cleanup to finish before terminating, including when the request comes from the delete-and-relaunch task.

The submodules point at the upstream projects, unchanged. Serein's changes to them are patches in `Tools/vendor-patches`, which `apply-vendor-patches.sh` applies (`build-app.sh` runs this automatically):

| Patch | Change |
|---|---|
| `grdb-sqlcipher.patch` | Builds GRDB against SQLCipher (the encrypted database), as GRDB's own instructions describe |
| `libsignal-aes-cbc.patch` | Exposes libsignal's AES-256-CBC to Swift, so attachment encryption needs no CommonCrypto pointer code |
| `libsignal-call-link-endorsements.patch` | Exposes libsignal’s existing call-link endorsement operations to SignalCore for sealed signaling to admitted participants |
| `libsignal-media.patch` | Builds libsignal's media sanitizers (WebP, MP4) and their Swift API, used on outgoing stickers and media |
| `libsignal-local-test-server.patch` | Lets the integration tests connect libsignal-net to the local mock server (tests only) |

For interoperability tests, `Tools/build-ringrtc-ffi.sh` builds the native reference library using Serein’s C interface and Signal’s pinned WebRTC artifact. The optional test peer has its own package in `Packages/SignalCallingInterop`. SQLCipher ships in the app’s Frameworks directory. [Calling QA](QA.md)

After changing a patched file under `vendor/`, regenerate its patch (`git -C vendor/libsignal diff`, minus the other patches' changes), because changes to a submodule's files are not part of Serein's own commits.

The first launch of a sandboxed build moves your existing data into the app's container. The data moved is the databases and attachments in `~/Library/Application Support/signal-safe` (and `signal-safe-staging`) plus the preferences file. They end up in `~/Library/Containers/org.signalsafe.SignalSafe`. The database key stays in your login keychain. Older, unsandboxed builds will not find the data afterwards.

Choose **Share screen** during a call and select what to share. Without global Screen Recording permission, Serein opens the macOS picker, which grants access to the screen, window, or app you select. If Serein already has Screen Recording permission, it shows its own list of screens and windows.

Ending a call releases the camera, the microphone and screen capture, however the call ends: you hang up, close the lobby, the other side hangs up (including the hang-up that leaves the "needs permission" screen up), or the call fails. Setting up a call, starting the camera and starting a screen share all have to wait, for the database, credentials, a permission prompt or the device itself. Each step checks once its wait is over that the call it belongs to is still current, so a hang-up during setup always wins. A call the app is not showing is ended instead of left running. The tests suspend each of these waits, hang up, then let them finish and check that nothing started.

Each package has its own tests:

```sh
(cd Packages/SignalCodecs && swift test)
(cd Packages/SignalMediaService && swift test --skip Live)   # drop --skip Live to hit Giphy and real sites
(cd Packages/SignalCore && swift test)    # uses the mock server: Tools/build-mock-server.sh
(cd Packages/SignalUI && swift test)
Tools/lint-codecs.sh                      # memory-safety and isolation rules
Tools/check-sandbox-profile.sh            # the Seatbelt profiles and peer checks, after build-app.sh
```

The app's attachment-drop regression runs with
`swift test --package-path App/SignalSafe --filter AttachmentDropTests`. Promised-file
callbacks in the native composer are explicitly `@Sendable`: reading and removing the
delivered file runs on AppKit's background delivery queue, and staging hops to the main
actor. Chat drops consume SwiftUI's item providers instead of requesting the same file
promise again; SwiftUI owns that delivery and its cache. A file a provider hands over is
NSItemProvider's copy of what the drag's source wrote, read like a promise in the composer: a
regular file with one link, opened without following a link. The copy keeps a symbolic link a
link (refused) but turns a hard link into a plain file, which only the composer's folder can
tell apart. Tests cover background callback staging, provider-backed images, Finder file
URLs, symbolic links to other files and file ownership. They do
not simulate a native drag gesture. `swift test --package-path Packages/SignalUI --filter
AttachmentRemovalTests` clicks a staged image's remove button and checks that only that image
is removed, without opening the editor.

`Tools/check-sandbox-profile.sh` does three things:
- It runs a probe under each profile and checks what the probe may and may not do.
- It runs the real services from the built app on test media, a voice note, a live link preview and a Giphy search.
- It checks that every service refuses a host signed with a different identifier.

The link preview and Giphy search need network access.

## Layout

| Path | What it holds |
|---|---|
| `App/SignalSafe` | The app target |
| `Packages/SignalCodecs` | Media parsers, decoders and encoders (no Foundation, no `unsafe`) |
| `Packages/SignalMediaService` | The XPC services, their XPC interface, wire format and containment, and their Seatbelt profiles (`Sandbox/`) |
| `Packages/SignalCore` | Protocol stores, database (SQLCipher), messaging, groups, storage service, attachments, calling |
| `Packages/SignalText` | Link detection and the link-preview URL rules, shared by the app and the fetcher |
| `Packages/SignalUI` | The SwiftUI interface |
| `Packages/SignalI18n` | ICU MessageFormat runtime and the translated strings |
| `Packages/SignalRingRTC` | Swift calling API and engine, sandboxed XPC service, and native reference bridge for tests |
| `Tools` | Build scripts, generators, lint and the sandbox check |
| `Signal-Desktop` | The upstream client, used as a read-only reference |

## License

Serein is licensed under the GNU Affero General Public License v3.0 (see [LICENSE](LICENSE)). Its interface and translations are ported from [Signal Desktop](https://github.com/signalapp/Signal-Desktop), which uses the same license.
