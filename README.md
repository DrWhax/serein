<p align="center"><img src="Logo/Serein.png" width="128" alt="Serein logo"></p>

# Serein

A native Signal client for macOS. Built with SwiftUI, with every image and video format decoded in Swift inside a sandbox, and a focus on security.

> [!WARNING]
> **Serein is experimental software.** Do not rely on it for strong cryptography or security yet. No one has formally verified that its crypto code is implemented safely.

Serein is not affiliated with or endorsed by Signal Messenger LLC.

## What it is

- **Native app.** Built with SwiftUI and AppKit instead of Electron. The interface follows Signal Desktop's design closely.
- **Linked device only.** You link Serein to the Signal app on your phone with a QR code. Backups, payments and donations are not supported.
- **Swift media decoders.** Every image, audio and video format is decoded by Swift code in `Packages/SignalCodecs`. Serein never uses ImageIO, VideoToolbox or AudioToolbox on untrusted data. Each format has a grammar-first parser written in the LangSec style. Supported formats:
  - images: PNG/APNG, JPEG, GIF, WebP, BMP/ICO and AVIF (AV1 key frames, 8/10-bit);
  - video and audio: MP4, H.264, HEVC, AAC and MP3;
  - HEIC photos you send are converted to JPEG first, as Signal Desktop does.
- **Untrusted data stays out of the app.** Media, web pages and Giphy's API responses are handled by separate sandboxed XPC services, never by the app. Voice notes are encoded in a service of their own. See [Isolation](#isolation).
- **Signal's libraries for the protocol.** The protocol, networking and calling come from Signal's own Rust libraries ([libsignal](https://github.com/signalapp/libsignal) and [RingRTC](https://github.com/signalapp/ringrtc)). Serein does not reimplement them.

## Isolation

Serein runs as six processes. Each one runs under App Sandbox and the hardened runtime, and has its own Seatbelt profile in `Packages/SignalMediaService/Sandbox`. The profile's rules are added to the sandbox through the process's entitlements.

| Process | What it does | What it can reach |
|---|---|---|
| `Serein.app` | Interface, keys, database, Signal protocol, calls | Its own container, the network, camera, microphone, files you pick, its crash reports (read-only). It cannot start programs or send Apple events. |
| `SignalMediaDecoder.xpc` | Decodes received images, audio and video, converts HEIC | Nothing: no files, network, preferences, devices or Mach services (except the system's code-signing helper, which the peer checks need). |
| `SignalLinkPreviewFetcher.xpc` | Fetches link-preview pages and images | HTTPS to public internet addresses only: not this machine, not your local network. No files, no writes. |
| `SignalLinkPreviewParser.xpc` | Parses the fetched HTML | Nothing, like the decoder. It accepts HTML only from the fetcher. |
| `SignalGifSearch.xpc` | Searches Giphy through Signal's content proxy and parses the replies | HTTPS to the web. Not this machine, not your files, no writes. |
| `SignalVoiceNoteEncoder.xpc` | Encodes the voice notes you record to MP3 | Nothing, like the decoder. It links no decoder of received data. |

**Link previews.** The app never fetches or parses a web page:

1. The app asks the parser for a private (anonymous) XPC endpoint and passes it to the fetcher.
2. The fetcher fetches the page. It follows Signal Desktop's rules: redirects are followed one hop at a time, every hop must be previewable, and the HTML is limited to 1000 KiB and the image to 1 MiB.
3. The fetcher sends the HTML to the parser over that endpoint and gets back the title, description, date and image link.
4. The app receives the checked result and the image bytes. The decoder checks the image and re-encodes it (GIFs are only checked) before the app shows it.

Pages are fetched directly from the site, as Signal Desktop does. Unlike Signal Desktop, the fetcher refuses a host (on any hop) that resolves to a private, loopback, link-local or other non-public address, so a link cannot point it at your router or printer. It resolves each host itself before connecting. A DNS answer that changes between that check and the connection (DNS rebinding) is not caught.

**Peer checks.**
- Every XPC connection is limited, in both directions, to the code signature of the process it expects (`NSXPCConnection.setCodeSigningRequirement`). The system drops messages from anything else before they are delivered.
- `Tools/build-app.sh` writes each component's requirement into every bundle's `Info.plist` (`SereinXPCPeers`):
  - With a signing identity, the requirement is the bundle identifier plus your Team ID, under an Apple certificate.
  - Ad-hoc builds (the default) can only require the bundle identifier. Anyone can sign another program ad hoc with the same identifier, so use a signing identity for real use.
- The app checks every reply for size and type before it uses it.

**Messages between processes.** Requests and replies use a strict binary format (`MediaXPCInterface/Wire.swift`), not a general one like property lists:
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

**Not isolated yet.** Calls (RingRTC) still run in the app process. The app also records the microphone for voice notes itself and hands the samples to the encoder.

## Requirements

- macOS 27 on Apple silicon
- Xcode 27 (Swift 6.4)
- A Rust toolchain, to build libsignal and RingRTC

## Building

```sh
git submodule update --init
Tools/apply-vendor-patches.sh
CARGO_BUILD_TARGET=aarch64-apple-darwin vendor/libsignal/swift/build_ffi.sh --release
vendor/ringrtc/bin/fetch-artifact --platform mac-arm64 --release
Tools/build-ringrtc-ffi.sh
SIGNALSAFE_SIGN_IDENTITY=<codesign identity> Tools/build-app.sh
open App/SignalSafe/.build/Serein.app
```

The submodules point at the upstream projects, unchanged. Serein's changes to them are patches in `Tools/vendor-patches`, which `apply-vendor-patches.sh` applies (`build-app.sh` applies them again, which does nothing if they are already in):

| Patch | Change |
|---|---|
| `grdb-sqlcipher.patch` | Builds GRDB against SQLCipher (the encrypted database), as GRDB's own instructions describe |
| `libsignal-aes-cbc.patch` | Exposes libsignal's AES-256-CBC to Swift, so attachment encryption needs no CommonCrypto pointer code |
| `libsignal-media.patch` | Builds libsignal's media sanitizers (WebP, MP4) and their Swift API, used on outgoing stickers and media |
| `libsignal-local-test-server.patch` | Lets the integration tests connect libsignal-net to the local mock server (tests only) |

RingRTC is used unpatched. Serein's own C interface over it is `Packages/SignalRingRTC/rust`, built against the prebuilt WebRTC that `fetch-artifact` downloads and checks against RingRTC's published checksum. `build-app.sh` copies the resulting `libsignal_ringrtc.dylib` and SQLCipher into `Serein.app/Contents/Frameworks` and signs them with the app.

After changing a patched file under `vendor/`, regenerate its patch (`git -C vendor/libsignal diff`, minus the other patches' changes), because changes to a submodule's files are not part of Serein's own commits.

The first launch of a sandboxed build moves your existing data into the app's container. The data moved is the databases and attachments in `~/Library/Application Support/signal-safe` (and `signal-safe-staging`) plus the preferences file. They end up in `~/Library/Containers/org.signalsafe.SignalSafe`. The database key stays in your login keychain. Older, unsandboxed builds will not find the data afterwards.

Screen sharing in calls uses ScreenCaptureKit. macOS asks for Screen Recording permission the first time you share; App Sandbox has no entitlement for it.

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
| `Packages/SignalRingRTC` | C ABI and Swift wrapper over RingRTC |
| `Tools` | Build scripts, generators, lint and the sandbox check |
| `Signal-Desktop` | The upstream client, used as a read-only reference |

## License

Serein is licensed under the GNU Affero General Public License v3.0 (see [LICENSE](LICENSE)). Its interface and translations are ported from [Signal Desktop](https://github.com/signalapp/Signal-Desktop), which uses the same license.
